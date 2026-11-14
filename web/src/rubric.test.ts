import { describe, expect, it } from "vitest";
import type { RubricView } from "./api";
import {
  categoriesFor,
  categoryProblem,
  commentCategoryProblem,
  commitTitle,
  comparePair,
  errorWhere,
  extraFields,
  reviewCategoryProblem,
  rubricLabel,
  rubricOfJob,
  rubricPath,
  rubricState,
  shortSha,
  showValue,
  storedCategories,
  togglePick,
  typeExtras,
  type RubricDoc,
} from "./rubric";

const sha = "0123456789abcdef0123456789abcdef01234567";

const doc: RubricDoc = {
  defaultRubric: "No `sorry`.",
  prTypes: [
    {
      name: "feature",
      description: "Adds definitions.",
      rubric: "Check names.",
      categories: [
        { name: "correctness", description: "Wrong." },
        { name: "naming", description: "Names.", colour: "blue" },
      ],
      weight: 2,
    },
    { name: "refactor", description: "Moves.", rubric: "Nothing lost.", categories: [] },
  ],
};

const view: RubricView = {
  owner: "acme",
  name: "widgets",
  repository: "chrisflav/review-rubrics",
  branch: "main",
  directory: "acme/widgets",
  sha,
  headSha: sha,
  checkedAt: "2026-11-14T10:00:00Z",
  error: null,
  exists: true,
  defaultRubric: doc.defaultRubric,
  prTypes: doc.prTypes,
  fanout: false,
  styleNotes: "",
  files: [],
  treeUrl: "https://github.com/chrisflav/review-rubrics/tree/main/acme/widgets",
  legacyVersion: null,
  derivedFrom: [],
  derivedFromPulls: [],
};

describe("categoriesFor", () => {
  it("answers the type's categories, or none for a type that lists none: free text", () => {
    expect(categoriesFor(doc, "feature")).toEqual(["correctness", "naming"]);
    expect(categoriesFor(doc, "refactor")).toEqual([]);
  });

  it("answers every category of the document for a review of no type it names", () => {
    const d: RubricDoc = {
      ...doc,
      prTypes: [
        ...doc.prTypes,
        {
          name: "docs",
          description: "",
          rubric: "",
          categories: [
            { name: "naming", description: "" },
            { name: "style", description: "" },
          ],
        },
      ],
    };
    expect(categoriesFor(d, null)).toEqual(["correctness", "naming", "style"]);
    expect(categoriesFor(d, "gone")).toEqual(["correctness", "naming", "style"]);
    expect(categoriesFor({ prTypes: [] }, null)).toEqual([]);
  });

  it("follows the job's rubric as the server does", () => {
    expect(rubricOfJob({ rubricSha: sha, rubricVersion: null })).toEqual({ kind: "sha", sha });
    expect(rubricOfJob({ rubricSha: sha, rubricVersion: 3 })).toEqual({ kind: "sha", sha });
    expect(rubricOfJob({ rubricSha: null, rubricVersion: 0 })).toEqual({ kind: "none" });
    expect(rubricOfJob({ rubricSha: null, rubricVersion: null })).toEqual({ kind: "current" });
    expect(rubricOfJob({ rubricSha: null, rubricVersion: 4 })).toEqual({ kind: "current" });
  });
});

describe("categoryProblem", () => {
  const allowed = ["correctness", "naming"];
  it("takes a rubric category, none, or free text where the rubric names none", () => {
    expect(categoryProblem("naming", allowed)).toBeNull();
    expect(categoryProblem(undefined, allowed)).toBeNull();
    expect(categoryProblem("anything", [])).toBeNull();
  });

  it("refuses another category, blank or too long ones", () => {
    expect(categoryProblem("style", allowed)).toMatch(/not a category of the rubric/);
    expect(categoryProblem(" ", [])).toMatch(/1 to 100/);
    expect(categoryProblem("x".repeat(101), [])).toMatch(/1 to 100/);
  });

  it("lets a category stand that the stored comment with the same id has, as the server does", () => {
    const stored = storedCategories({
      decision: "comment",
      body: "",
      comments: [
        { file: "a", start_line: 1, end_line: 1, body: "x", id: "c1", category: "style" },
        { file: "a", start_line: 2, end_line: 2, body: "y", category: "style" },
      ],
    });
    const c = { file: "a", start_line: 1, end_line: 1, body: "x", category: "style" };
    expect(commentCategoryProblem({ ...c, id: "c1" }, allowed, stored)).toBeNull();
    // Another id, or none at all, is checked: the server checks it too.
    expect(commentCategoryProblem({ ...c, id: "c2" }, allowed, stored)).toMatch(/not a category/);
    expect(commentCategoryProblem(c, allowed, stored)).toMatch(/not a category/);
    const review = { decision: "comment" as const, body: "", comments: [{ ...c, id: "c1" }, c] };
    expect(reviewCategoryProblem(review, allowed, stored)).toMatch(/^Comment 2: /);
  });
});

describe("naming a job's rubric", () => {
  it("is the commit, short, and else the legacy version", () => {
    expect(shortSha(sha)).toBe("0123456");
    expect(rubricLabel({ rubricSha: sha, rubricVersion: 3 })).toBe("0123456");
    expect(rubricLabel({ rubricSha: null, rubricVersion: 3 })).toBe("v3");
    expect(rubricLabel({ rubricSha: null, rubricVersion: 0 })).toBe("none");
    expect(rubricLabel({ rubricSha: null, rubricVersion: null })).toBeNull();
    // A server older than API 1.0.0 sends no sha at all.
    expect(rubricLabel({ rubricVersion: 2 })).toBe("v2");
  });

  it("links the rubric page at the commit", () => {
    expect(rubricPath("a/b", "c")).toBe("/repos/a%2Fb/c/rubric");
    expect(rubricPath("a", "c", sha)).toBe(`/repos/a/c/rubric?sha=${sha}`);
    expect(rubricPath("a", "c", null)).toBe("/repos/a/c/rubric");
  });
});

describe("rubricState", () => {
  it("says when no rubrics repository is configured", () => {
    expect(rubricState({ ...view, repository: null, sha: null })).toEqual({
      kind: "unconfigured",
    });
  });

  it("says why there is no rubric at all", () => {
    const error = { file: null, line: null, message: "the branch main does not exist" };
    expect(rubricState({ ...view, sha: null, error })).toEqual({ kind: "none", error });
  });

  it("says when the head does not parse and the last good commit is in use", () => {
    const error = { file: "acme/widgets/rubric.md", line: 3, message: "bad front matter" };
    expect(rubricState(view)).toEqual({ kind: "rubric", headBroken: false });
    expect(rubricState({ ...view, error })).toEqual({ kind: "rubric", headBroken: true });
    expect(errorWhere(error)).toBe("acme/widgets/rubric.md, line 3");
    expect(errorWhere({ ...error, line: null })).toBe("acme/widgets/rubric.md");
    expect(errorWhere({ ...error, file: null })).toBe("");
  });
});

describe("unknown front matter", () => {
  it("is what the view has beyond the fields this build knows", () => {
    expect(extraFields(view)).toEqual([]);
    expect(extraFields({ ...view, reviewers: ["kim"], weight: 2 })).toEqual([
      ["reviewers", ["kim"]],
      ["weight", 2],
    ]);
    expect(typeExtras(doc.prTypes[0]!)).toEqual([["weight", 2]]);
    expect(typeExtras({ ...doc.prTypes[1]!, fanout: true })).toEqual([]);
  });

  it("is shown as text", () => {
    expect(showValue("green")).toBe("green");
    expect(showValue(["kim"])).toBe('["kim"]');
    expect(showValue({ a: 1 })).toBe('{"a":1}');
  });
});

describe("the history", () => {
  const items = [{ sha: "c3" }, { sha: "c2" }, { sha: "c1" }];

  it("shows a commit by its first line", () => {
    expect(commitTitle("Tighten naming\n\nAs asked in #104.")).toBe("Tighten naming");
    expect(commitTitle("One line")).toBe("One line");
  });

  it("picks at most two commits to compare, letting go of the earlier pick", () => {
    expect(togglePick([], "c1")).toEqual(["c1"]);
    expect(togglePick(["c1"], "c3")).toEqual(["c1", "c3"]);
    expect(togglePick(["c1", "c3"], "c2")).toEqual(["c3", "c2"]);
    expect(togglePick(["c1", "c3"], "c1")).toEqual(["c3"]);
  });

  it("compares the older with the newer, whichever was picked first", () => {
    expect(comparePair(items, "c1", "c3")).toEqual({ base: "c1", head: "c3" });
    expect(comparePair(items, "c3", "c2")).toEqual({ base: "c2", head: "c3" });
    expect(comparePair(items, "c3", "c3")).toBeNull();
    expect(comparePair(items, "c3", "c0")).toBeNull();
  });
});