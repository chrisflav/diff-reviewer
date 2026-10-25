import { describe, expect, it } from "vitest";
import { parseDiff } from "./diff";
import { commentProblem, parseReview, placeComments, toLocal, toReview } from "./review";

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
    expect(byLine?.get(2)?.map((c) => c.key)).toEqual([0]);
    expect(byLine?.get(3)?.map((c) => c.key)).toEqual([1, 6]);
    expect(byLine?.get(21)?.map((c) => c.key)).toEqual([2]);
  });

  it("keeps every comment the diff cannot place, in order", () => {
    // Line 5 is not shown, b.ts is not in the diff, and gone.ts has no new side.
    expect(p.outside.map((c) => c.key)).toEqual([3, 4, 5]);
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
      '{"decision":"comment","body":"","comments":[{"file":"a","start_line":1,"end_line":1,"body":"x","suggestion":null}]}',
    );
    expect(ok).toEqual({
      decision: "comment",
      body: "",
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
});