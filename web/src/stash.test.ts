import { beforeEach, describe, expect, it } from "vitest";
import { KEY, toLocal, toReview } from "./review";
import { dropStash, stash, unstash } from "./stash";

// Node has no session storage; a map stands in for it.
const store = new Map<string, string>();
Object.defineProperty(globalThis, "sessionStorage", {
  value: {
    getItem: (k: string) => store.get(k) ?? null,
    setItem: (k: string, v: string) => store.set(k, v),
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