import { describe, expect, it } from "vitest";
import type { InlineComment, Review } from "./api";
import { parseDiff } from "./diff";
import {
  align,
  canKeepBoth,
  commentProblem,
  freeze,
  fromJson,
  KEY,
  MAX_COMMENTS,
  mergeComment,
  parseReview,
  placeComments,
  rebase,
  resolve,
  sameReview,
  thaw,
  toLocal,
  toReview,
  type LocalComment,
  type LocalReview,
} from "./review";

const diff = parseDiff(`diff --git a/a.ts b/a.ts
--- a/a.ts
+++ b/a.ts
@@ -1,3 +1,3 @@
 one
-two
+TWO
 three
@@ -20,2 +20,3 @@
 twenty
+new
 twenty-one
diff --git a/gone.ts b/gone.ts
deleted file mode 100644
--- a/gone.ts
+++ /dev/null
@@ -1 +0,0 @@
-x
`);

const comment = (file: string, start_line: number, end_line: number) => ({
  file,
  start_line,
  end_line,
  body: `${file}:${start_line}-${end_line}`,
});

describe("placeComments", () => {
  const local = toLocal({
    decision: "comment",
    body: "",
    comments: [
      comment("a.ts", 2, 2),
      comment("a.ts", 1, 3),
      comment("a.ts", 2, 21),
      comment("a.ts", 5, 5),
      comment("b.ts", 1, 1),
      comment("gone.ts", 1, 1),
      comment("a.ts", 3, 3),
    ],
  });
  const p = placeComments(diff, local.comments);

  it("puts a comment under the new-side line it ends on", () => {
    const byLine = p.anchored.get("a.ts");
    expect(byLine?.get(2)?.map((c) => c[KEY])).toEqual([0]);
    expect(byLine?.get(3)?.map((c) => c[KEY])).toEqual([1, 6]);
    expect(byLine?.get(21)?.map((c) => c[KEY])).toEqual([2]);
  });

  it("keeps every comment the diff cannot place, in order", () => {
    // Line 5 is not shown, b.ts is not in the diff, and gone.ts has no new side.
    expect(p.outside.map((c) => c[KEY])).toEqual([3, 4, 5]);
    const placed = [...(p.anchored.get("a.ts")?.values() ?? [])].flat().length;
    expect(placed + p.outside.length).toBe(local.comments.length);
  });

  it("flags a range that starts in another hunk than it ends", () => {
    expect([...p.split]).toEqual([2]);
  });

  it("marks the shown lines a comment covers", () => {
    expect([...(p.covered.get("a.ts") ?? [])].sort((a, b) => a - b)).toEqual([1, 2, 3, 20, 21]);
  });
});

describe("toReview", () => {
  it("drops the keys and writes no suggestion key when there is none", () => {
    const r = toReview(
      toLocal({
        decision: "approve",
        body: "b",
        comments: [comment("a.ts", 1, 1), { ...comment("a.ts", 2, 2), suggestion: "x" }],
      }),
    );
    expect(JSON.stringify(r)).toBe(
      JSON.stringify({
        decision: "approve",
        body: "b",
        comments: [
          { file: "a.ts", start_line: 1, end_line: 1, body: "a.ts:1-1" },
          { file: "a.ts", start_line: 2, end_line: 2, body: "a.ts:2-2", suggestion: "x" },
        ],
      }),
    );
  });
});

describe("commentProblem", () => {
  it("mirrors Review.validate", () => {
    expect(commentProblem(comment("a.ts", 1, 2))).toBeNull();
    expect(commentProblem(comment(" ", 1, 1))).not.toBeNull();
    expect(commentProblem(comment("a.ts", 0, 1))).not.toBeNull();
    expect(commentProblem(comment("a.ts", 3, 2))).not.toBeNull();
    expect(commentProblem({ ...comment("a.ts", 1, 1), body: " " })).not.toBeNull();
    // A suggestion alone says something, even an empty one: it deletes the lines.
    expect(commentProblem({ ...comment("a.ts", 1, 1), body: "", suggestion: "" })).toBeNull();
  });
});

describe("parseReview", () => {
  it("reads a review and refuses what is not one", () => {
    const ok = parseReview(
      '{"decision":"comment","body":"s","comments":[{"file":"a","start_line":1,"end_line":1,"body":"x","suggestion":null}]}',
    );
    expect(ok).toEqual({
      decision: "comment",
      body: "s",
      comments: [{ file: "a", start_line: 1, end_line: 1, body: "x" }],
    });
    expect(typeof parseReview("{")).toBe("string");
    expect(typeof parseReview('{"decision":"maybe","body":"","comments":[]}')).toBe("string");
    expect(typeof parseReview('{"decision":"comment","body":"","comments":[{}]}')).toBe("string");
    expect(
      typeof parseReview(
        '{"decision":"comment","body":"","comments":[{"file":"a","start_line":2,"end_line":1,"body":"x"}]}',
      ),
    ).toBe("string");
  });

  it("mirrors Review.validate's rules for the whole review", () => {
    const comment = { file: "a", start_line: 1, end_line: 1, body: "x" };
    const review = (decision: string, body: string, n: number) =>
      JSON.stringify({ decision, body, comments: Array.from({ length: n }, () => comment) });
    // An empty summary is refused, except on an approval.
    expect(parseReview(review("comment", " ", 0))).toMatch(/summary is empty/);
    expect(parseReview(review("request_changes", "", 0))).toMatch(/summary is empty/);
    expect(typeof parseReview(review("approve", "", 0))).toBe("object");
    expect(typeof parseReview(review("comment", "s", MAX_COMMENTS))).toBe("object");
    expect(parseReview(review("comment", "s", MAX_COMMENTS + 1))).toMatch(/at most 200/);
  });
});

const c0: InlineComment = {
  file: "a.ts",
  start_line: 1,
  end_line: 1,
  body: "one",
  category: "style",
  severity: "minor",
};
const c1: InlineComment = {
  file: "a.ts",
  start_line: 5,
  end_line: 6,
  body: "two",
  suggestion: "x",
  severity: "major",
};
const c2: InlineComment = { file: "b.ts", start_line: 3, end_line: 3, body: "three" };
const extra: Review = {
  decision: "comment",
  body: "summary",
  rubric: { name: "default", version: 2 },
  comments: [c0, c1, c2],
};

describe("fields this page does not know", () => {
  it("survive toLocal and toReview, with no key left behind", () => {
    const back = toReview(toLocal(extra));
    expect(back).toEqual(extra);
    expect(JSON.parse(JSON.stringify(back))).toEqual(extra);
  });

  it("survive editing one comment, and a suggestion turned off goes", () => {
    const [, two] = toLocal(extra).comments;
    if (two === undefined) throw new Error("fixture");
    const edited = mergeComment(two, { file: "a.ts", start_line: 5, end_line: 7, body: "TWO" });
    expect(toReview({ ...toLocal(extra), comments: [edited] }).comments[0]).toEqual({
      file: "a.ts",
      start_line: 5,
      end_line: 7,
      body: "TWO",
      severity: "major",
    });
    expect(edited[KEY]).toBe(two[KEY]);
  });

  it("survive Edit as JSON", () => {
    const parsed = parseReview(JSON.stringify(extra));
    expect(parsed).toEqual(extra);
  });

  it("survive storage, keys and all", () => {
    const local = toLocal(extra, [7, 3, 9]);
    const back = thaw(JSON.parse(JSON.stringify(freeze(local))));
    expect(back === null ? null : toReview(back)).toEqual(extra);
    expect(back?.comments.map((c) => c[KEY])).toEqual([7, 3, 9]);
    expect(thaw({ review: extra, keys: [1] })).toBeNull();
    expect(thaw("nonsense")).toBeNull();
  });

  it("survive a rebase on either side", () => {
    const base = toLocal(extra);
    const mine: LocalReview = { ...base, body: "mine" };
    const theirs = { ...extra, severityScale: "v2" };
    const r = rebase(base, mine, theirs);
    expect(r.conflicts).toEqual([]);
    expect(toReview(r.review)).toEqual({ ...extra, body: "mine", severityScale: "v2" });
  });
});

describe("fromJson", () => {
  it("keeps the keys of the comments it keeps, and gives new ones fresh keys", () => {
    const base = toLocal(extra, [0, 1, 2]);
    // Comment one moved to another file, three deleted, two edited, a new one added.
    const text = JSON.stringify({
      ...extra,
      comments: [
        { ...c0, file: "moved.ts", body: "one, moved" },
        { ...c1, body: "two, edited" },
        { file: "c.ts", start_line: 1, end_line: 1, body: "new" },
      ],
    });
    // Two is found by its place; one and the new comment pair up with what is left, in order,
    // as an edit in place of the same list would: one is one, the new comment takes three's.
    const r = fromJson(text, base, base);
    if (typeof r === "string") throw new Error(r);
    expect(r.comments.map((c) => c[KEY])).toEqual([0, 1, 2]);
    const longer = fromJson(
      JSON.stringify({ ...extra, comments: [...extra.comments, { ...c2, body: "4" }] }),
      base,
      base,
    );
    if (typeof longer === "string") throw new Error(longer);
    expect(longer.comments.map((c) => c[KEY])).toEqual([0, 1, 2, 3]);
    expect(typeof fromJson("{", base, base)).toBe("string");
  });

  it("does not hand out a key the base used for a comment the edits deleted", () => {
    const base = toLocal(extra, [0, 1, 2]);
    const current: LocalReview = { ...base, comments: base.comments.slice(0, 2) };
    const text = JSON.stringify({
      ...extra,
      comments: [
        ...extra.comments.slice(0, 2),
        { file: "z", start_line: 1, end_line: 1, body: "z" },
      ],
    });
    const r = fromJson(text, current, base);
    if (typeof r === "string") throw new Error(r);
    expect(r.comments.map((c) => c[KEY])).toEqual([0, 1, 3]);
  });
});

describe("align", () => {
  it("matches same comments, then comments at the same place, and nothing by position", () => {
    const known = toLocal(extra).comments;
    let next = 10;
    const out = align(
      known,
      [
        { file: "b.ts", start_line: 3, end_line: 3, body: "three, edited" },
        c0,
        { file: "q.ts", start_line: 1, end_line: 1, body: "new" },
      ],
      false,
      () => next++,
    );
    expect(out.map((c) => c[KEY])).toEqual([2, 0, 10]);
  });
});

describe("rebase", () => {
  const base = toLocal(extra);
  const [one, two, three] = base.comments as [
    (typeof base.comments)[0],
    (typeof base.comments)[0],
    (typeof base.comments)[0],
  ];

  it("takes each side's changes where the other did not touch the thing", () => {
    // Mine: the summary, comment one's body, a new comment. Theirs: the decision, comment
    // two's body, comment three deleted, a new comment of their own.
    const mine: LocalReview = {
      ...base,
      body: "my summary",
      comments: [
        { ...one, body: "one, mine" },
        two,
        three,
        { file: "m.ts", start_line: 1, end_line: 1, body: "my new", [KEY]: 3 },
      ],
    };
    const theirs: Review = {
      ...extra,
      decision: "request_changes",
      comments: [
        c0,
        { ...c1, body: "two, theirs" },
        { file: "t.ts", start_line: 1, end_line: 1, body: "their new" },
      ],
    };
    const r = rebase(base, mine, theirs);
    expect(r.conflicts).toEqual([]);
    const out = toReview(r.review);
    expect(out.decision).toBe("request_changes");
    expect(out.body).toBe("my summary");
    expect(out.rubric).toEqual(extra.rubric);
    expect(out.comments.map((c) => c.body)).toEqual([
      "one, mine",
      "two, theirs",
      "their new",
      "my new",
    ]);
    // The kept fields of the edited comments.
    expect(out.comments[0]?.category).toBe("style");
    expect(out.comments[1]?.severity).toBe("major");
    // My new comment and theirs do not share a key.
    const keys = r.review.comments.map((c) => c[KEY]);
    expect(new Set(keys).size).toBe(keys.length);
  });

  it("flags what both changed differently, leaves theirs until a side is picked", () => {
    const mine: LocalReview = {
      ...base,
      body: "mine",
      comments: [{ ...one, body: "one, mine" }, { ...two, body: "two, mine" }, three],
    };
    const theirs = {
      ...extra,
      body: "theirs",
      // One edited by them too, two deleted by them.
      comments: [{ ...c0, body: "one, theirs" }, c2],
    };
    const r = rebase(base, mine, theirs);
    expect(r.conflicts.map((c) => (c.kind === "field" ? c.name : c.key))).toEqual(["body", 0, 1]);
    expect(toReview(r.review)).toEqual(theirs);

    let out = r.review;
    for (const c of r.conflicts) out = resolve(out, c, "mine");
    expect(toReview(out).body).toBe("mine");
    expect(toReview(out).comments.map((c) => c.body)).toEqual(["one, mine", "three", "two, mine"]);
    // Picking again goes back.
    for (const c of r.conflicts) out = resolve(out, c, "theirs");
    expect(toReview(out)).toEqual(theirs);
  });

  it("sees the same change on both sides as no conflict", () => {
    const mine: LocalReview = { ...base, comments: [one, { ...two, body: "same" }] };
    const theirs = { ...extra, comments: [c0, { ...c1, body: "same" }] };
    const r = rebase(base, mine, theirs);
    expect(r.conflicts).toEqual([]);
    expect(toReview(r.review)).toEqual(theirs);
  });

  it("keeps edits made while a save was on its way", () => {
    // What was sent became the saved review; the edits since are changes to it.
    const sent: LocalReview = { ...base, body: "sent" };
    const now: LocalReview = { ...sent, comments: [one, two] };
    const r = rebase(sent, now, toReview(sent));
    expect(r.conflicts).toEqual([]);
    expect(toReview(r.review)).toEqual(toReview(now));
  });
  // Regressions: the other side may hold this person's own changes, or move what they edited.
  const cmt = (file: string, s0: number, e0: number, body: string): InlineComment => ({
    file,
    start_line: s0,
    end_line: e0,
    body,
  });
  const trio = toLocal({
    decision: "comment",
    body: "S",
    comments: [cmt("a", 1, 1, "one"), cmt("a", 5, 5, "two"), cmt("a", 9, 9, "three")],
  });
  const lines = (r: LocalReview) =>
    toReview(r).comments.map((x) => `${x.file}:${x.start_line}-${x.end_line} ${x.body}`);

  it("takes theirs equal to mine as nothing to merge, not as a second copy", () => {
    // A save of these edits that landed though its answer was lost.
    const mine: LocalReview = {
      ...trio,
      comments: [
        ...trio.comments.map((x) => (x[KEY] === 1 ? { ...x, start_line: 4, body: "two!" } : x)),
        { ...cmt("b", 2, 2, "new"), [KEY]: 3 },
      ],
    };
    const r = rebase(trio, mine, toReview(mine));
    expect(r.conflicts).toEqual([]);
    expect(lines(r.review)).toEqual(lines(mine));
    expect(sameReview(r.review, r.base)).toBe(true);
  });

  it("keeps a comment they moved and I reworded as one comment, with both changes", () => {
    const theirs = toReview({
      ...trio,
      comments: trio.comments.map((x) => (x[KEY] === 1 ? { ...x, start_line: 4 } : x)),
    });
    const mine: LocalReview = {
      ...trio,
      comments: trio.comments.map((x) => (x[KEY] === 1 ? { ...x, body: "two edited" } : x)),
    };
    const r = rebase(trio, mine, theirs);
    expect(r.conflicts).toEqual([]);
    expect(lines(r.review)).toEqual(["a:1-1 one", "a:4-5 two edited", "a:9-9 three"]);
  });

  it("shows a comment they replaced in its file as changed, and a pick leaves one", () => {
    const theirs: Review = {
      ...toReview(trio),
      comments: [cmt("a", 6, 6, "other"), cmt("a", 1, 1, "one")],
    };
    const mine: LocalReview = {
      ...trio,
      comments: trio.comments.map((x) => (x[KEY] === 1 ? { ...x, body: "two edited" } : x)),
    };
    const r = rebase(trio, mine, theirs);
    const c = r.conflicts.find((x) => x.kind === "comment");
    if (c === undefined || c.kind !== "comment") throw new Error("no conflict");
    expect([c.mine?.body, c.theirs?.body]).toEqual(["two edited", "other"]);
    const picked = resolve(r.review, c, "mine");
    expect(lines(picked).filter((x) => x.startsWith("a:5") || x.includes("other"))).toEqual([
      "a:5-5 two edited",
    ]);
    expect(lines(resolve(picked, c, "theirs"))).toEqual(lines(r.review));
  });

  it("lands their deletion of one of two identical comments on the copy I did not edit", () => {
    const dup = toLocal({
      decision: "comment",
      body: "S",
      comments: [cmt("a", 1, 1, "dup"), cmt("a", 1, 1, "dup")],
    });
    const edited: LocalReview = {
      ...dup,
      comments: [
        dup.comments[0] as LocalComment,
        { ...(dup.comments[1] as LocalComment), body: "dup edited" },
      ],
    };
    const r = rebase(dup, edited, { ...toReview(dup), comments: [cmt("a", 1, 1, "dup")] });
    expect(r.conflicts).toEqual([]);
    expect(lines(r.review)).toEqual(["a:1-1 dup edited"]);
    // Both deleting a copy leaves one, not none.
    const deleted: LocalReview = { ...dup, comments: [dup.comments[1] as LocalComment] };
    const d = rebase(dup, deleted, { ...toReview(dup), comments: [cmt("a", 1, 1, "dup")] });
    expect(lines(d.review)).toEqual(["a:1-1 dup"]);
  });

  it("matches by id where both sides carry one, and guesses nothing for them", () => {
    const withIds = toLocal({
      decision: "comment",
      body: "S",
      comments: [
        { ...cmt("a", 1, 1, "same text"), id: "c1" },
        { ...cmt("a", 1, 1, "same text"), id: "c2" },
      ],
    });
    // They moved and reworded c2 and deleted c1; I edited c1. Without ids nothing ties the
    // reworded comment to c2; with them it is c2, and c1's deletion meets my edit.
    const mine: LocalReview = {
      ...withIds,
      comments: withIds.comments.map((x) => (x.id === "c1" ? { ...x, body: "mine" } : x)),
    };
    const theirs: Review = {
      ...toReview(withIds),
      comments: [{ ...cmt("b", 7, 7, "theirs, moved"), id: "c2" }],
    };
    const r = rebase(withIds, mine, theirs);
    expect(r.base.comments.map((x) => x[KEY])).toEqual([1]);
    expect(r.conflicts.map((x) => (x.kind === "comment" ? [x.key, x.theirs] : null))).toEqual([
      [0, null],
    ]);
    // A new comment with an id is new, however much it looks like an old one.
    const added = rebase(withIds, withIds, {
      ...toReview(withIds),
      comments: [...toReview(withIds).comments, { ...cmt("a", 1, 1, "same text"), id: "c3" }],
    });
    expect(added.base.comments.map((x) => x[KEY])).toEqual([0, 1, 2]);
    // And Edit as JSON keys by id too.
    const j = fromJson(JSON.stringify(theirs), withIds, withIds);
    if (typeof j === "string") throw new Error(j);
    expect(j.comments.map((x) => x[KEY])).toEqual([1]);
  });

  // Second re-review: merges that mixed two places, or two comments, without a word.
  const single = (c: InlineComment) => toLocal({ decision: "comment", body: "S", comments: [c] });
  const edit = (r: LocalReview, k: number, f: (c: LocalComment) => LocalComment): LocalReview => ({
    ...r,
    comments: r.comments.map((x) => (x[KEY] === k ? f(x) : x)),
  });

  it("takes a comment's lines, file and suggestion as one: both changing them is a conflict", () => {
    const b = single({ ...cmt("a", 5, 5, "use const"), suggestion: "const x = 1;" });
    const widen = edit(b, 0, (x) => ({ ...x, start_line: 4 }));
    const suggest = edit(b, 0, (x) => ({ ...x, suggestion: "const x = 2;" }));
    const moveFile = edit(b, 0, (x) => ({ ...x, file: "b" }));
    for (const [mine, theirs] of [
      [widen, suggest],
      [suggest, widen],
      [moveFile, widen],
    ] as const) {
      const r = rebase(b, mine, toReview(theirs));
      expect(r.conflicts).toHaveLength(1);
      expect(toReview(r.review)).toEqual(toReview(theirs));
    }
    // A body change still merges with a change of place.
    const reword = edit(b, 0, (x) => ({ ...x, body: "prefer const" }));
    const r = rebase(b, reword, toReview(widen));
    expect(r.conflicts).toEqual([]);
    expect(toReview(r.review).comments[0]).toEqual({
      ...cmt("a", 4, 5, "prefer const"),
      suggestion: "const x = 1;",
    });
  });

  it("does not guess which of two comments saying the same was moved", () => {
    const b = toLocal({
      decision: "comment",
      body: "S",
      comments: [cmt("a", 5, 5, "nit: naming"), cmt("a", 9, 9, "nit: naming")],
    });
    // They delete X and move Y to 10; I edit X. My edit must not land on line 10.
    const mine = edit(b, 0, (x) => ({ ...x, body: "nit: call it count" }));
    const r = rebase(b, mine, { ...toReview(b), comments: [cmt("a", 10, 10, "nit: naming")] });
    const placed = lines(r.review);
    expect(placed).not.toContain("a:10-10 nit: call it count");
    const c = r.conflicts.find((x) => x.kind === "comment");
    if (c === undefined || c.kind !== "comment") throw new Error("no conflict");
    expect(c.mine === null ? null : lines({ ...b, comments: [c.mine] })).toEqual([
      "a:5-5 nit: call it count",
    ]);
    expect(lines(resolve(r.review, c, "mine"))).toContain("a:5-5 nit: call it count");
  });

  it("pairs a deleted comment only with a new one by its lines, and offers keeping both", () => {
    const b = single(cmt("a", 5, 5, "x"));
    const mine = edit(b, 0, (x) => ({ ...x, body: "x!" }));
    // Far away: another comment, not this one changed. Keeping mine keeps theirs too.
    const far = rebase(b, mine, { ...toReview(b), comments: [cmt("a", 40, 40, "unrelated")] });
    const fc = far.conflicts[0];
    if (fc === undefined) throw new Error("no conflict");
    expect(canKeepBoth(fc)).toBe(false);
    expect(lines(resolve(far.review, fc, "mine"))).toEqual(["a:40-40 unrelated", "a:5-5 x!"]);
    // Nearby: offered as the same comment changed, with "both" as a choice.
    const near = rebase(b, mine, { ...toReview(b), comments: [cmt("a", 6, 7, "y")] });
    const nc = near.conflicts[0];
    if (nc === undefined) throw new Error("no conflict");
    expect(canKeepBoth(nc)).toBe(true);
    expect(lines(resolve(near.review, nc, "mine"))).toEqual(["a:5-5 x!"]);
    expect(lines(resolve(near.review, nc, "both"))).toEqual(["a:6-7 y", "a:5-5 x!"]);
    expect(lines(resolve(resolve(near.review, nc, "both"), nc, "theirs"))).toEqual(["a:6-7 y"]);
  });
});