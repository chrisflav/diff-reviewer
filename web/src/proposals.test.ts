import { afterEach, describe, expect, it, vi } from "vitest";
import { ApiError, type Repo, type RubricDocument, type RubricProposal } from "./api";
import {
  acceptProposal,
  acceptRefusal,
  acceptRequest,
  adoptionEdits,
  adoptRubricPath,
  diffCounts,
  loadAdoption,
  notesAdoptionEdits,
  parseInline,
  parseRationale,
  rubricUnchanged,
  saveRubricEdits,
} from "./proposals";
import { formOf, mergeRepoSettings, putBody } from "./repoSettings";
import { documentOf, rebaseRubric, toRubricDoc } from "./rubric";

const v1: RubricDocument = {
  owner: "o",
  name: "n",
  version: 1,
  createdAt: "t1",
  defaultRubric: "No sorry.",
  prTypes: [
    {
      name: "feature",
      description: "New things.",
      rubric: "Check names.",
      categories: [{ name: "naming", description: "Names." }],
      colour: "green",
    },
  ],
  documentError: null,
};

const v2: RubricDocument = {
  ...v1,
  version: 2,
  createdAt: "t2",
  prTypes: [{ ...v1.prTypes![0]!, description: "New definitions or theorems." }],
};

const proposal: RubricProposal = {
  id: "p1",
  owner: "o",
  name: "n",
  jobId: "j1",
  status: "pending",
  baseVersion: 1,
  currentVersion: 2,
  rebaseNeeded: true,
  rationale: "Because.",
  proposesStyleNotes: true,
  createdAt: "t",
  decidedAt: null,
  acceptedVersion: null,
  document: {
    defaultRubric: "No sorry.\nNo admit.",
    prTypes: [
      {
        ...v1.prTypes![0]!,
        categories: [...v1.prTypes![0]!.categories, { name: "docs", description: "Docs." }],
      },
    ],
  },
  documentError: null,
  styleNotes: "Be brief.",
  baseStyleNotes: "",
  diff: null,
  diffError: null,
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

describe("acceptRequest", () => {
  it("leaves the style notes out unless asked", () => {
    expect(acceptRequest(proposal)).toEqual({ version: 2, applyStyleNotes: false });
    expect(acceptRequest(proposal, true)).toEqual({ version: 2, applyStyleNotes: true });
  });

  it("never asks for notes a proposal does not have", () => {
    expect(acceptRequest({ ...proposal, proposesStyleNotes: false }, true)).toEqual({
      version: 2,
      applyStyleNotes: false,
    });
  });
});

describe("acceptRefusal", () => {
  it("reads a moved rubric from the 409's body", () => {
    const err = new ApiError(409, "moved", { error: "moved", baseVersion: 1, currentVersion: 2 });
    expect(acceptRefusal(err)).toEqual({
      kind: "moved",
      baseVersion: 1,
      currentVersion: 2,
      message: "moved",
    });
  });

  it("takes any other 409 as refused, and anything else as not a refusal", () => {
    expect(acceptRefusal(new ApiError(409, "notes changed", { error: "notes changed" }))).toEqual({
      kind: "refused",
      message: "notes changed",
    });
    expect(acceptRefusal(new ApiError(400, "bad"))).toBeNull();
    expect(acceptRefusal(new Error("x"))).toBeNull();
  });
});

describe("adoptionEdits", () => {
  it("is the proposal as edits to its base, which the merge moves onto the current version", () => {
    const e = adoptionEdits("o", "n", proposal, v1);
    if (typeof e === "string") throw new Error(e);
    expect(e.version).toBe(1);
    expect(e.fromProposal).toBe("p1");
    const r = rebaseRubric(e.base, e.doc, documentOf(v2)!);
    expect(r.conflicts).toEqual([]);
    const merged = toRubricDoc(r.review);
    // The proposal's changes and the rubric's since, both kept; the field it did not know, too.
    expect(merged.defaultRubric).toBe("No sorry.\nNo admit.");
    expect(merged.prTypes[0]?.description).toBe("New definitions or theorems.");
    expect(merged.prTypes[0]?.categories.map((c) => c.name)).toEqual(["naming", "docs"]);
    expect(merged.prTypes[0]?.colour).toBe("green");
  });

  it("asks where the proposal and the rubric changed the same thing differently", () => {
    const e = adoptionEdits("o", "n", proposal, v1);
    if (typeof e === "string") throw new Error(e);
    const theirs = { ...v2, defaultRubric: "No sorry, ever." };
    const r = rebaseRubric(e.base, e.doc, documentOf(theirs)!);
    expect(r.conflicts.map((c) => c.kind)).toEqual(["field"]);
  });

  it("asks about a type the proposal and the rubric since both added under one name", () => {
    const docs = { name: "docs", description: "Proposed.", rubric: "", categories: [] };
    const p = { ...proposal, document: { ...proposal.document!, prTypes: [...v1.prTypes!, docs] } };
    const e = adoptionEdits("o", "n", p, v1);
    if (typeof e === "string") throw new Error(e);
    const theirs = { ...v2, prTypes: [...v2.prTypes!, { ...docs, description: "Saved." }] };
    const r = rebaseRubric(e.base, e.doc, documentOf(theirs)!);
    expect(r.conflicts.map((c) => c.kind)).toEqual(["type"]);
    expect(toRubricDoc(r.review).prTypes.map((t) => t.name)).toEqual(["feature", "docs"]);
  });

  it("refuses a rejected proposal, and one this build cannot read", () => {
    expect(typeof adoptionEdits("o", "n", { ...proposal, status: "rejected" }, v1)).toBe("string");
    expect(typeof adoptionEdits("o", "n", { ...proposal, document: null }, v1)).toBe("string");
  });

  it("takes version 0 as the empty rubric", () => {
    const e = adoptionEdits("o", "n", { ...proposal, baseVersion: 0 }, null);
    if (typeof e === "string") throw new Error(e);
    expect(e.base.prTypes).toEqual([]);
    expect(e.version).toBe(0);
  });
});

describe("notesAdoptionEdits", () => {
  const repo: Repo = {
    owner: "o",
    name: "n",
    mode: "staged",
    autoReview: false,
    trustedReviewers: ["alice"],
    styleNotes: "",
    evalShare: 50,
    styleNotesVersion: 0,
    version: 4,
    createdAt: "t",
  };

  it("takes the proposal's notes when the repository's are still those the agent read", () => {
    const e = notesAdoptionEdits(repo, proposal);
    if (typeof e === "string") throw new Error(e);
    const m = mergeRepoSettings(e.base, e.form, formOf(repo));
    expect(m.conflicts).toEqual([]);
    expect(m.form.styleNotes).toBe("Be brief.");
    expect(putBody(repo, m.form, e.fromProposal)).toMatchObject({
      styleNotes: "Be brief.",
      fromProposal: "p1",
      version: 4,
    });
  });

  it("asks when the notes changed since, and keeps them until a side is picked", () => {
    const now = { ...repo, styleNotes: "Suggest, don't ask." };
    const e = notesAdoptionEdits(now, proposal);
    if (typeof e === "string") throw new Error(e);
    const m = mergeRepoSettings(e.base, e.form, formOf(now));
    expect(m.conflicts).toEqual([
      { field: "styleNotes", mine: "Be brief.", theirs: "Suggest, don't ask." },
    ]);
    expect(m.form.styleNotes).toBe("Suggest, don't ask.");
  });

  it("refuses a proposal with no notes", () => {
    expect(typeof notesAdoptionEdits(repo, { ...proposal, styleNotes: null })).toBe("string");
  });
});

describe("the accept flow", () => {
  afterEach(() => vi.unstubAllGlobals());

  /** A fetch that answers `routes` by method and path, recording every request. */
  function fake(routes: Record<string, (body: unknown) => [number, unknown]>) {
    const calls: { key: string; body: unknown }[] = [];
    vi.stubGlobal("fetch", async (path: string, init: RequestInit) => {
      const key = `${init.method} ${path}`;
      const body = init.body === undefined ? undefined : JSON.parse(String(init.body));
      calls.push({ key, body });
      const route = routes[key];
      if (route === undefined) return new Response('{"error":"no route"}', { status: 404 });
      const [status, out] = route(body);
      return new Response(JSON.stringify(out), { status });
    });
    return calls;
  }

  it("goes from a 409 for a moved rubric to the editor, whose save names the proposal", async () => {
    const calls = fake({
      "POST /api/v1/repos/o/n/proposals/p1/accept": () => [
        409,
        { error: "the rubric has moved", baseVersion: 1, currentVersion: 2 },
      ],
      "GET /api/v1/repos/o/n/proposals/p1": () => [200, proposal],
      "GET /api/v1/repos/o/n/rubrics": () => [200, v2],
      "GET /api/v1/repos/o/n/rubrics/history?limit=1&offset=1": () => [
        200,
        { items: [v1], nextOffset: null },
      ],
      "PUT /api/v1/repos/o/n/rubrics": (b) => [200, { ...v2, ...(b as object), version: 3 }],
    });

    // Accepting, the style notes not asked for, is refused: the rubric moved.
    const err = await acceptProposal(proposal).catch((e: unknown) => e);
    expect(calls[0]?.body).toEqual({ version: 2, applyStyleNotes: false });
    const why = acceptRefusal(err);
    expect(why?.kind).toBe("moved");
    expect(adoptRubricPath("o", "n", "p1")).toBe("/repos/o/n/rubric?proposal=p1");

    // The editor loads the proposal over its base, and moves it onto the current version.
    const e = await loadAdoption("o", "n", "p1");
    if (typeof e === "string") throw new Error(e);
    const r = rebaseRubric(e.base, e.doc, documentOf(v2)!);
    expect(r.conflicts).toEqual([]);

    // Saved over version 2, naming the proposal.
    await saveRubricEdits("o", "n", { ...e, version: 2, base: r.base, doc: r.review });
    const put = calls.find((c) => c.key === "PUT /api/v1/repos/o/n/rubrics");
    expect(put?.body).toMatchObject({
      version: 2,
      fromProposal: "p1",
      defaultRubric: "No sorry.\nNo admit.",
    });
  });

  it("sends no fromProposal for edits of one's own", async () => {
    const calls = fake({
      "PUT /api/v1/repos/o/n/rubrics": () => [200, { ...v2, version: 3 }],
    });
    const e = adoptionEdits("o", "n", proposal, v1);
    if (typeof e === "string") throw new Error(e);
    const own = { ...e };
    delete own.fromProposal;
    await saveRubricEdits("o", "n", own);
    expect(calls[0]?.body).not.toHaveProperty("fromProposal");
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