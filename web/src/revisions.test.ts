import { describe, expect, it } from "vitest";
import type { InlineComment, Review, Revision } from "./api";
import {
  commentProblem,
  countSeverity,
  filterComments,
  mergeComment,
  parseReview,
  toLocal,
} from "./review";
import { diffReviews, draftAndPosted, isEmptyDiff, lineDiff, readRevision } from "./revisions";

const c = (
  id: string | undefined,
  line: number,
  body: string,
  more: Partial<InlineComment> = {},
) => ({
  ...(id === undefined ? {} : { id }),
  file: "a.lean",
  start_line: line,
  end_line: line,
  body,
  ...more,
});

const draft: Review = {
  decision: "request_changes",
  body: "Two things.\nFirst.\nSecond.",
  comments: [
    c("aa", 1, "Wrong.", { severity: "blocker", category: "correctness" }),
    c("bb", 5, "Rename.", { severity: "nit", category: "naming" }),
    c("cc", 9, "Docs."),
  ],
};

const posted: Review = {
  decision: "comment",
  body: "Two things.\nFirst.\nSecond, reworded.",
  comments: [
    c("bb", 6, "Rename.", { severity: "minor", category: "naming" }),
    c("aa", 1, "Wrong.", { severity: "blocker", category: "correctness" }),
    c("dd", 12, "New."),
  ],
};

const rev = (version: number, author: string, review: unknown): Revision => ({
  jobId: "j",
  version,
  author,
  review,
  reviewError: null,
  createdAt: `2026-10-25T10:0${version}:00Z`,
});

describe("diffReviews", () => {
  it("matches comments by id, whatever their order or place", () => {
    const d = diffReviews(draft, posted);
    expect(d.decision).toEqual({ before: "request_changes", after: "comment" });
    expect(d.body).not.toBeNull();
    expect(d.unchanged).toBe(1);
    expect(d.changed).toHaveLength(1);
    expect(d.changed[0]!.before.id).toBe("bb");
    expect(d.changed[0]!.fields).toEqual(["place", "severity"]);
    expect(d.removed.map((x) => x.id)).toEqual(["cc"]);
    expect(d.added.map((x) => x.id)).toEqual(["dd"]);
    expect(d.guessed).toBe(0);
  });

  it("does not pair two comments with different ids, even saying the same", () => {
    const a = { ...draft, comments: [c("aa", 1, "Same.")] };
    const b = { ...draft, comments: [c("zz", 1, "Same.")] };
    const d = diffReviews(a, b);
    expect(d.added).toHaveLength(1);
    expect(d.removed).toHaveLength(1);
  });

  it("pairs comments without ids by content, then by a place only one is at", () => {
    const a = { ...draft, comments: [c(undefined, 1, "One."), c(undefined, 4, "Four.")] };
    const b = { ...draft, comments: [c(undefined, 4, "Four, edited."), c(undefined, 1, "One.")] };
    const d = diffReviews(a, b);
    expect(d.unchanged).toBe(1);
    expect(d.changed.map((x) => x.fields)).toEqual([["body"]]);
    expect(d.guessed).toBe(2);
    // Two at one place are not told apart by a guess.
    const two = { ...draft, comments: [c(undefined, 1, "x"), c(undefined, 1, "y")] };
    const other = { ...draft, comments: [c(undefined, 1, "z"), c(undefined, 1, "w")] };
    expect(diffReviews(two, other).added).toHaveLength(2);
  });

  it("pairs a comment stored without an id with the one that got an id on the next write", () => {
    const a = { ...draft, comments: [c(undefined, 1, "One."), c(undefined, 5, "Five.")] };
    const b = { ...draft, comments: [c("i1", 1, "One."), c("i2", 5, "Five, edited.")] };
    const d = diffReviews(a, b);
    expect([d.added.length, d.removed.length, d.changed.length, d.unchanged]).toEqual([0, 0, 1, 1]);
    expect(d.changed[0]!.fields).toEqual(["body"]);
    expect(d.guessed).toBe(2);
  });

  it("names other fields that changed, and finds nothing between equal reviews", () => {
    const d = diffReviews(draft, { ...draft, event: "COMMENT" });
    expect(d.other).toEqual(["event"]);
    expect(isEmptyDiff(diffReviews(draft, structuredClone(draft)))).toBe(true);
  });
});

describe("readRevision", () => {
  it("reads what is stored, and says why it cannot", () => {
    expect(readRevision(rev(1, "agent", draft))).toEqual(draft);
    expect(readRevision({ ...rev(1, "agent", null), reviewError: "not JSON" })).toBe("not JSON");
    expect(typeof readRevision(rev(1, "agent", { decision: "x" }))).toBe("string");
  });
});

describe("draftAndPosted", () => {
  it("is the agent's first draft and the last of what GitHub holds", () => {
    const revs = [
      rev(1, "agent", draft),
      rev(2, "person", posted),
      rev(3, "github", posted),
      rev(4, "agent", draft),
      rev(5, "github", draft),
    ];
    const p = draftAndPosted(revs);
    expect(p?.draft.version).toBe(1);
    expect(p?.final.version).toBe(5);
    expect(p?.posted).toBe(true);
  });

  it("falls back to the latest revision before posting, and is nothing without a draft", () => {
    const p = draftAndPosted([rev(1, "agent", draft), rev(2, "person", posted)]);
    expect(p?.final.version).toBe(2);
    expect(p?.posted).toBe(false);
    expect(draftAndPosted([rev(1, "person", posted)])).toBeNull();
  });
});

describe("lineDiff", () => {
  it("keeps common lines and marks the rest", () => {
    expect(lineDiff("a\nb\nc", "a\nB\nc")).toEqual([
      { kind: "same", text: "a" },
      { kind: "del", text: "b" },
      { kind: "add", text: "B" },
      { kind: "same", text: "c" },
    ]);
    expect(lineDiff("", "x")).toEqual([{ kind: "add", text: "x" }]);
  });
});

describe("categories and severities on comments", () => {
  const base = toLocal(draft).comments[0]!;

  it("are edited by the form, and an emptied one removed", () => {
    const edited = mergeComment(base, { ...c("aa", 1, "Wrong."), severity: "major" }, true);
    expect(edited.severity).toBe("major");
    expect("category" in edited).toBe(false);
    expect(edited.id).toBe("aa");
  });

  it("are kept when the edit does not touch them", () => {
    const edited = mergeComment(base, c("aa", 1, "Wrong, again."));
    expect(edited.category).toBe("correctness");
    expect(edited.severity).toBe("blocker");
  });

  it("are checked as the server checks them", () => {
    expect(commentProblem(c("aa", 1, "x", { category: " \t" }))).toMatch(/category/);
    expect(commentProblem(c("aa", 1, "x", { category: "y".repeat(101) }))).toMatch(/category/);
    expect(commentProblem(c("aa", 1, "x", { category: "y".repeat(100) }))).toBeNull();
    const bad = { ...draft, comments: [c("aa", 1, "x", { severity: "huge" as never })] };
    expect(parseReview(JSON.stringify(bad))).toMatch(/severity/);
    const nulls = { ...draft, comments: [{ ...c("aa", 1, "x"), category: null, severity: null }] };
    const read = parseReview(JSON.stringify(nulls));
    expect(typeof read).not.toBe("string");
    expect((read as Review).comments[0]).toEqual(c("aa", 1, "x"));
  });

  it("filter and sort", () => {
    const cs = draft.comments;
    expect(
      filterComments(cs, { severities: [], category: "" }, "severity").map((x) => x.id),
    ).toEqual(["aa", "bb", "cc"]);
    expect(
      filterComments(cs, { severities: ["nit", "none"], category: "" }, "place").map((x) => x.id),
    ).toEqual(["bb", "cc"]);
    expect(
      filterComments(cs, { severities: [], category: "naming" }, "place").map((x) => x.id),
    ).toEqual(["bb"]);
    expect(
      filterComments(cs, { severities: [], category: null }, "place").map((x) => x.id),
    ).toEqual(["cc"]);
    expect(
      filterComments(cs, { severities: [], category: "" }, "category").map((x) => x.id),
    ).toEqual(["aa", "bb", "cc"]);
    expect(countSeverity(draft, "blocker")).toBe(1);
    expect(countSeverity(null, "major")).toBe(0);
  });
});