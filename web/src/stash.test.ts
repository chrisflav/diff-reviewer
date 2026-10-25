import { beforeEach, describe, expect, it } from "vitest";
import { KEY, toLocal, toReview } from "./review";
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
});