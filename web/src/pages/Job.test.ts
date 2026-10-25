import { describe, expect, it } from "vitest";
import type { Job } from "../api";
import { parseDiff } from "../diff";
import { placeComments, toLocal } from "../review";
import { postBlockers } from "./Job";

const job: Job = {
  id: "j",
  owner: "o",
  name: "n",
  prNumber: 1,
  headSha: "aaaa",
  status: "approved",
  queueEntry: null,
  review: null,
  reviewError: null,
  version: 1,
  createdAt: "",
  updatedAt: "",
};

const text = `diff --git a/a b/a
--- a/a
+++ b/a
@@ -1,2 +1,2 @@
 one
-two
+TWO
@@ -10,1 +10,1 @@
-ten
+TEN
`;
const files = parseDiff(text);
const place = (lines: [number, number][]) =>
  placeComments(
    files,
    toLocal({
      decision: "comment",
      body: "",
      comments: lines.map(([s, e]) => ({ file: "a", start_line: s, end_line: e, body: "x" })),
    }).comments,
  );

describe("postBlockers", () => {
  const diff = { headSha: "aaaa", diff: text };

  it("lets a clean review through", () => {
    expect(postBlockers(job, false, diff, null, place([[1, 2]]))).toEqual([]);
  });

  it("holds back unsaved edits, a missing or foreign diff, and comments GitHub refuses", () => {
    expect(postBlockers(job, true, diff, null, place([]))).toHaveLength(1);
    expect(postBlockers(job, false, null, "404", place([]))).toHaveLength(1);
    expect(postBlockers(job, false, { ...diff, headSha: "bbbb" }, null, place([]))).toHaveLength(1);
    expect(postBlockers(job, false, diff, null, place([[5, 5]]))[0]).toMatch(/outside the diff/);
    expect(postBlockers(job, false, diff, null, place([[1, 10]]))[0]).toMatch(/more than one hunk/);
  });
});