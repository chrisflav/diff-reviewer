import { beforeEach, describe, expect, it } from "vitest";
import {
  conflictId,
  freshKeys,
  KEY,
  rebase,
  resolve,
  sameReview,
  toLocal,
  toReview,
} from "./review";
import {
  freshRubricKeys,
  RKEY,
  rebaseRubric,
  resolveRubric,
  rubricConflictId,
  sameRubric,
  toLocalRubric,
  toRubricDoc,
  type RubricDoc,
} from "./rubric";
import {
  dropStash,
  reopen,
  reopenRepo,
  stashRepo,
  unstashRepo,
  reopenRubric,
  rubricStashKey,
  stash,
  stashRubric,
  unstash,
  unstashRubric,
} from "./stash";

// Node has no session storage; a map stands in for it, one that can be made to refuse writes.
const store = new Map<string, string>();
let full = false;
Object.defineProperty(globalThis, "sessionStorage", {
  value: {
    getItem: (k: string) => store.get(k) ?? null,
    setItem: (k: string, v: string) => {
      if (full) throw new Error("QuotaExceededError");
      store.set(k, v);
    },
    removeItem: (k: string) => store.delete(k),
  },
});

const review = {
  decision: "comment" as const,
  body: "b",
  rubric: "r1",
  comments: [{ file: "a", start_line: 1, end_line: 1, body: "x", severity: "minor" as const }],
};

describe("stash", () => {
  beforeEach(() => store.clear());

  it("gives back the edits as they were, keys and unknown fields too", () => {
    const base = toLocal(review, [4]);
    const edited = { ...base, body: "edited", comments: [...base.comments] };
    stash({ jobId: "j1", version: 3, base, review: edited });
    const back = unstash("j1");
    expect(back?.version).toBe(3);
    expect(back === null ? null : toReview(back.review)).toEqual({ ...review, body: "edited" });
    expect(back?.base.comments.map((c) => c[KEY])).toEqual([4]);
    expect(unstash("j2")).toBeNull();
    dropStash("j1");
    expect(unstash("j1")).toBeNull();
  });

  it("ignores what it cannot read", () => {
    store.set("diff-reviewer:edits:j1", "{not json");
    expect(unstash("j1")).toBeNull();
    store.set("diff-reviewer:edits:j1", JSON.stringify({ jobId: "other", version: 1 }));
    expect(unstash("j1")).toBeNull();
  });
});

describe("stash with open conflicts", () => {
  beforeEach(() => {
    store.clear();
    full = false;
  });

  it("brings back open conflicts, the sides picked and the edits made since, after a 401", () => {
    // Version 1 edited here; version 2 saved elsewhere meanwhile; a 409, and the edits are moved.
    const base = toLocal({ ...review, comments: [{ ...review.comments[0]!, id: "c1" }] });
    const mine = {
      ...base,
      body: "mine",
      comments: base.comments.map((c) => ({ ...c, body: "mine" })),
    };
    const theirs = {
      ...toReview(base),
      body: "theirs",
      comments: toReview(base).comments.map((c) => ({ ...c, body: "theirs" })),
    };
    const r = rebase(base, mine, theirs);
    expect(r.conflicts.map(conflictId)).toEqual([
      "field:body",
      `comment:${base.comments[0]![KEY]}`,
    ]);
    const source = { jobId: "j1", version: 1, base, review: mine };
    // One side picked, and a comment added since; the other conflict still open.
    const first = r.conflicts[0]!;
    const picks = { [conflictId(first)]: "mine" as const };
    const picked = resolve(r.review, first, "mine");
    const added = { file: "b", start_line: 2, end_line: 2, body: "new" };
    const now = {
      ...picked,
      comments: [...picked.comments, { ...added, [KEY]: freshKeys(picked, r.base)() }],
    };
    expect(
      stash({ jobId: "j1", version: 2, base: r.base, review: now }, { from: 1, source, picks }),
    ).toBe(true);

    // The page is gone: everything comes back from storage alone.
    const back = unstash("j1");
    expect(back?.pending?.picks).toEqual(picks);
    const reopened = reopen(back!);
    expect(reopened).not.toBeNull();
    expect(sameReview(reopened!.edits.review, now)).toBe(true);
    expect(toReview(reopened!.edits.review).body).toBe("mine");
    expect(reopened!.rebased?.conflicts.map(conflictId)).toEqual(r.conflicts.map(conflictId));
    expect(reopened!.rebased?.picks).toEqual(picks);
    const open = reopened!.rebased!.conflicts[1]!;
    expect(toReview(resolve(reopened!.edits.review, open, "mine")).comments[0]!.body).toBe("mine");
  });

  it("reopens edits without conflicts as they were", () => {
    const base = toLocal(review);
    stash({ jobId: "j1", version: 1, base, review: { ...base, body: "x" } });
    const back = unstash("j1");
    expect(back?.pending).toBeNull();
    expect(reopen(back!)?.rebased).toBeNull();
  });
});

describe("stash failing", () => {
  beforeEach(() => {
    store.clear();
    full = false;
  });

  it("says so, and drops an older copy rather than offer it back", () => {
    const base = toLocal(review);
    expect(stash({ jobId: "j1", version: 1, base, review: { ...base, body: "first" } })).toBe(true);
    full = true;
    expect(stash({ jobId: "j1", version: 1, base, review: { ...base, body: "second" } })).toBe(
      false,
    );
    expect(unstash("j1")).toBeNull();
  });
});

describe("rubric stash", () => {
  beforeEach(() => {
    store.clear();
    full = false;
  });

  const doc: RubricDoc = {
    defaultRubric: "base",
    prTypes: [
      { name: "a", description: "", rubric: "ra", categories: [] },
      { name: "b", description: "", rubric: "rb", categories: [] },
    ],
  };

  it("is keyed by the repository as the server keys it", () => {
    expect(rubricStashKey("ChrisFlav", "Diff-Reviewer")).toBe("chrisflav/diff-reviewer");
  });

  it("brings back open conflicts, the sides picked and the edits made since, after a 401", () => {
    // Version 1 edited here; version 2 saved elsewhere meanwhile; a 409, and the edits are moved.
    const base = toLocalRubric(doc);
    const mine = {
      ...base,
      defaultRubric: "mine",
      prTypes: base.prTypes.map((t) => ({ ...t, rubric: `${t.rubric}-mine` })),
    };
    const theirs: RubricDoc = {
      defaultRubric: "theirs",
      prTypes: doc.prTypes.map((t) => ({ ...t, rubric: `${t.rubric}-theirs` })),
    };
    const r = rebaseRubric(base, mine, theirs);
    expect(r.conflicts).toHaveLength(3);
    const source = { repo: "o/n", version: 1, base, doc: mine };
    // One side picked, and an edit made since; the other two conflicts still open.
    const first = r.conflicts[0]!;
    const picks = { [rubricConflictId(first)]: "mine" as const };
    const picked = resolveRubric(r.review, first, "mine");
    const added = { name: "new", description: "", rubric: "", categories: [] };
    const now = {
      ...picked,
      prTypes: [...picked.prTypes, { ...added, [RKEY]: freshRubricKeys(picked, r.base)() }],
    };
    const edits = { repo: "o/n", version: 2, base: r.base, doc: now };
    expect(stashRubric(edits, { from: 1, source, picks })).toBe(true);

    // The page is gone: everything comes back from storage alone.
    const back = unstashRubric("o/n");
    expect(back?.pending?.picks).toEqual(picks);
    const reopened = reopenRubric(back!);
    expect(reopened).not.toBeNull();
    expect(sameRubric(reopened!.edits.doc, now)).toBe(true);
    expect(toRubricDoc(reopened!.edits.doc).prTypes.map((t) => t.name)).toEqual(["a", "b", "new"]);
    expect(reopened!.rebased?.conflicts.map(rubricConflictId)).toEqual(
      r.conflicts.map(rubricConflictId),
    );
    expect(reopened!.rebased?.picks).toEqual(picks);
    // An open conflict settles as it would have before.
    const open = reopened!.rebased!.conflicts[1]!;
    expect(toRubricDoc(resolveRubric(reopened!.edits.doc, open, "mine")).prTypes[0]!.rubric).toBe(
      "ra-mine",
    );
  });

  it("reopens edits without conflicts as they were", () => {
    const base = toLocalRubric(doc);
    stashRubric({ repo: "o/n", version: 1, base, doc: { ...base, defaultRubric: "x" } });
    const back = unstashRubric("o/n");
    expect(back?.pending).toBeNull();
    expect(reopenRubric(back!)?.rebased).toBeNull();
  });

  it("keeps across a 401 the proposal the edits adopt, so that the save still names it", () => {
    const base = toLocalRubric(doc);
    stashRubric({ repo: "o/n", version: 1, base, doc: base, fromProposal: "p1" });
    const back = unstashRubric("o/n");
    expect(back?.fromProposal).toBe("p1");
    expect(reopenRubric(back!)?.edits.fromProposal).toBe("p1");
  });

  it("keeps the proposal the edits from before a move adopt, with conflicts open", () => {
    const base = toLocalRubric(doc);
    const source = { repo: "o/n", version: 1, base, doc: base, fromProposal: "p1" };
    const edits = { repo: "o/n", version: 2, base, doc: base, fromProposal: "p1" };
    stashRubric(edits, { from: 1, source, picks: {} });
    expect(unstashRubric("o/n")?.pending?.source.fromProposal).toBe("p1");

    // Kept by a build that stored it with the edits alone: taken from there.
    const j = JSON.parse(store.get("diff-reviewer:rubric:o/n")!) as { pending: object };
    delete (j.pending as { fromProposal?: string }).fromProposal;
    store.set("diff-reviewer:rubric:o/n", JSON.stringify(j));
    expect(unstashRubric("o/n")?.pending?.source.fromProposal).toBe("p1");
  });
});

describe("repo settings stash", () => {
  beforeEach(() => store.clear());
  const base = {
    mode: "staged" as const,
    autoReview: false,
    trustedReviewers: ["alice"],
    styleNotes: "",
    evalShare: 50,
  };
  const edits = {
    repo: "o/n",
    version: 4,
    base: { ...base, mode: "direct" as const },
    form: { ...base, mode: "direct" as const, trustedReviewers: ["alice", "bob"] },
  };

  it("gives back the edits, and none pending", () => {
    expect(stashRepo(edits)).toBe(true);
    const s = unstashRepo("o/n");
    expect(s?.form).toEqual(edits.form);
    expect(s?.pending).toBeNull();
    expect(s === null ? null : reopenRepo(s)).toEqual({ edits, pending: null, conflicts: [] });
  });

  it("keeps the edits from before a move and the sides picked, with the edits", () => {
    const source = { repo: "o/n", version: 3, base, form: { ...base, autoReview: true } };
    expect(stashRepo(edits, { from: 3, source, picks: { mode: "theirs" } })).toBe(true);
    const s = unstashRepo("o/n");
    expect(s?.pending).toEqual({ from: 3, source, picks: { mode: "theirs" } });
  });

  it("restores the edits from before the move when its conflicts cannot be worked out again", () => {
    // Moving `source` onto `edits.base` gives no conflict: the stash is not what this build makes.
    const source = { repo: "o/n", version: 3, base, form: { ...base, autoReview: true } };
    stashRepo(edits, { from: 3, source, picks: {} });
    const s = unstashRepo("o/n");
    expect(s === null ? "none" : reopenRepo(s)).toBeNull();
  });

  it("refuses a stash it cannot read", () => {
    store.set("diff-reviewer:repo:o/n", JSON.stringify({ ...edits, savedAt: "t", pending: 3 }));
    expect(unstashRepo("o/n")).toBeNull();
  });

  it("keeps the proposal whose style notes the edits adopt", () => {
    stashRepo({ ...edits, fromProposal: "p1" });
    expect(unstashRepo("o/n")?.fromProposal).toBe("p1");
  });

  it("keeps it for the edits from before a move too, with conflicts open", () => {
    const source = { repo: "o/n", version: 3, base, form: base, fromProposal: "p1" };
    stashRepo({ ...edits, fromProposal: "p1" }, { from: 3, source, picks: {} });
    expect(unstashRepo("o/n")?.pending?.source).toEqual(source);

    const j = JSON.parse(store.get("diff-reviewer:repo:o/n")!) as { pending: object };
    delete (j.pending as { fromProposal?: string }).fromProposal;
    store.set("diff-reviewer:repo:o/n", JSON.stringify(j));
    expect(unstashRepo("o/n")?.pending?.source).toEqual(source);
  });

  it("keeps a share held out left empty, which JSON stores as null", () => {
    const empty = { ...edits, form: { ...edits.form, evalShare: Number.NaN } };
    expect(stashRepo(empty, { from: 3, source: empty, picks: {} })).toBe(true);
    const s = unstashRepo("o/n");
    expect(s?.form.evalShare).toBeNaN();
    expect(s?.pending?.source.form.evalShare).toBeNaN();
    expect(s?.base).toEqual(edits.base);
  });

  it("reads a stash from before the style notes, filled in alike on both sides", () => {
    const strip = (f: object) => {
      const o: Record<string, unknown> = { ...f };
      delete o.styleNotes;
      delete o.evalShare;
      return o;
    };
    store.set(
      "diff-reviewer:repo:o/n",
      JSON.stringify({
        ...edits,
        base: strip(edits.base),
        form: strip(edits.form),
        savedAt: "t",
        pending: null,
      }),
    );
    const s = unstashRepo("o/n");
    expect(s?.legacy).toBe(true);
    expect(s?.base.styleNotes).toBe(s?.form.styleNotes);
    expect(s?.form.trustedReviewers).toEqual(["alice", "bob"]);
  });
});