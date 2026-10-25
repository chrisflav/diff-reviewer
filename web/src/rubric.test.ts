import { describe, expect, it } from "vitest";
import type { RubricDocument } from "./api";
import {
  categoriesFor,
  categoryProblem,
  documentOf,
  freezeRubric,
  MAX_RUBRIC_BYTES,
  move,
  RKEY,
  rebaseRubric,
  resolveRubric,
  rubricProblems,
  rubricVersionOfJob,
  sameRubric,
  thawRubric,
  toLocalRubric,
  toRubricDoc,
  type RubricDoc,
} from "./rubric";

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
  future: { kept: true },
};

const messages = (d: RubricDoc) => rubricProblems(d).map((p) => p.message);

describe("rubricProblems", () => {
  it("accepts a good document", () => {
    expect(rubricProblems(doc)).toEqual([]);
  });

  it("refuses empty names, as the server trims them: ASCII whitespace only", () => {
    const d = { ...doc, prTypes: [{ ...doc.prTypes[0]!, name: " \t\n" }] };
    expect(messages(d)).toEqual(["pull request type 1 has an empty name"]);
    // A no-break space is not ASCII whitespace: the server takes it as a name.
    expect(messages({ ...doc, prTypes: [{ ...doc.prTypes[0]!, name: " " }] })).toEqual([]);
  });

  it("refuses names others have, compared exactly", () => {
    const twice = { ...doc, prTypes: [doc.prTypes[0]!, { ...doc.prTypes[1]!, name: "feature" }] };
    expect(messages(twice)).toContain("two pull request types are called 'feature'");
    const cats = [
      { name: "docs", description: "" },
      { name: "docs", description: "again" },
    ];
    expect(messages({ ...doc, prTypes: [{ ...doc.prTypes[1]!, categories: cats }] })).toContain(
      "'refactor' has two categories called 'docs'",
    );
    const cased = [
      { name: "docs", description: "" },
      { name: "Docs", description: "" },
    ];
    expect(messages({ ...doc, prTypes: [{ ...doc.prTypes[1]!, categories: cased }] })).toEqual([]);
  });

  it("counts a name in characters and a rubric in bytes", () => {
    const long = "é".repeat(100);
    expect(messages({ ...doc, prTypes: [{ ...doc.prTypes[1]!, name: long }] })).toEqual([]);
    // 100 astral characters are 200 UTF-16 units but 100 characters.
    expect(messages({ ...doc, prTypes: [{ ...doc.prTypes[1]!, name: "𝔸".repeat(100) }] })).toEqual(
      [],
    );
    expect(messages({ ...doc, prTypes: [{ ...doc.prTypes[1]!, name: `${long}x` }] })).toEqual([
      "pull request type 1's name is longer than 100 characters",
    ]);
    const half = "é".repeat(MAX_RUBRIC_BYTES / 2);
    expect(messages({ ...doc, defaultRubric: half })).toEqual([]);
    expect(messages({ ...doc, defaultRubric: `${half}x` })).toEqual([
      "the default rubric is longer than 65536 bytes",
    ]);
    expect(messages({ ...doc, prTypes: [{ ...doc.prTypes[1]!, rubric: `${half}x` }] })).toEqual([
      "the rubric of 'refactor' is longer than 65536 bytes",
    ]);
  });

  it("bounds the types and categories, and says where each problem is", () => {
    const types = Array.from({ length: 51 }, (_, i) => ({
      name: `t${i}`,
      description: "",
      rubric: "",
      categories: [],
    }));
    expect(messages({ ...doc, prTypes: types })).toEqual([
      "the document names 51 pull request types; at most 50",
    ]);
    const cats = Array.from({ length: 51 }, (_, i) => ({ name: `c${i}`, description: "" }));
    const ps = rubricProblems({
      ...doc,
      prTypes: [doc.prTypes[1]!, { ...doc.prTypes[0]!, categories: cats }],
    });
    expect(ps).toEqual([
      { message: "'feature' names 51 categories; at most 50", field: "categories", type: 1 },
    ]);
    const blank = rubricProblems({
      ...doc,
      prTypes: [{ ...doc.prTypes[0]!, categories: [{ name: "", description: "" }] }],
    });
    expect(blank).toEqual([
      { message: "category 1 of 'feature' has an empty name", field: "name", type: 0, category: 0 },
    ]);
  });
});

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
    expect(categoriesFor({ defaultRubric: "", prTypes: [] }, null)).toEqual([]);
  });

  it("follows the job's rubric version as the server does", () => {
    expect(rubricVersionOfJob(0)).toBe("none");
    expect(rubricVersionOfJob(null)).toBe("current");
    expect(rubricVersionOfJob(4)).toBe(4);
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

  it("lets a category the comment already had stand, as the server does", () => {
    expect(categoryProblem("style", allowed, "style")).toBeNull();
  });
});

describe("documents", () => {
  const version: RubricDocument = {
    owner: "o",
    name: "n",
    version: 3,
    createdAt: "2026-10-25T10:00:00Z",
    documentError: null,
    ...doc,
  };

  it("keep unknown fields through a round trip, and drop the version's own", () => {
    const d = documentOf(version);
    expect(d).toEqual(doc);
    const back = toRubricDoc(toLocalRubric(d!));
    expect(back).toEqual(doc);
    expect(JSON.parse(JSON.stringify(back))).toEqual(doc);
  });

  it("cannot be read when the server cannot", () => {
    expect(
      documentOf({ ...version, defaultRubric: null, prTypes: null, documentError: "bad" }),
    ).toBeNull();
  });

  it("freeze and thaw with their keys", () => {
    const local = toLocalRubric(doc);
    local.prTypes[0]![RKEY] = 7;
    const thawed = thawRubric(JSON.parse(JSON.stringify(freezeRubric(local))));
    expect(thawed).not.toBeNull();
    expect(thawed!.prTypes[0]![RKEY]).toBe(7);
    expect(sameRubric(thawed!, local)).toBe(true);
    expect(thawRubric({ doc, keys: { types: [1], cats: [] } })).toBeNull();
  });

  it("move", () => {
    expect(move([1, 2, 3], 0, 1)).toEqual([2, 1, 3]);
    expect(move([1, 2, 3], 0, -1)).toEqual([1, 2, 3]);
  });
});

describe("rebaseRubric", () => {
  const base = toLocalRubric(doc);
  const edit = (f: (d: RubricDoc) => RubricDoc) => toLocalRubric(f(structuredClone(doc)));

  it("takes both sides' changes to different things", () => {
    const mine = { ...base, defaultRubric: "Mine." };
    const theirs = structuredClone(doc);
    theirs.prTypes[1]!.rubric = "Theirs.";
    const r = rebaseRubric(base, mine, theirs);
    expect(r.conflicts).toEqual([]);
    const out = toRubricDoc(r.review);
    expect(out.defaultRubric).toBe("Mine.");
    expect(out.prTypes[1]!.rubric).toBe("Theirs.");
    expect(out.future).toEqual({ kept: true });
  });

  it("follows a type renamed on their side, by everything else being the same", () => {
    const mine = {
      ...base,
      prTypes: base.prTypes.map((t, i) => (i === 1 ? { ...t, rubric: "Mine." } : t)),
    };
    const theirs = structuredClone(doc);
    theirs.prTypes[1]!.name = "cleanup";
    const r = rebaseRubric(base, mine, theirs);
    expect(r.conflicts).toEqual([]);
    expect(toRubricDoc(r.review).prTypes.map((t) => [t.name, t.rubric])).toEqual([
      ["feature", "Check names."],
      ["cleanup", "Mine."],
    ]);
  });

  it("asks where both changed the same field, and settles it either way", () => {
    const mine = { ...base, defaultRubric: "Mine." };
    const r = rebaseRubric(base, mine, { ...doc, defaultRubric: "Theirs." });
    expect(r.conflicts).toHaveLength(1);
    expect(r.review.defaultRubric).toBe("Theirs.");
    const c = r.conflicts[0]!;
    expect(resolveRubric(r.review, c, "mine").defaultRubric).toBe("Mine.");
  });

  it("asks about a type deleted on one side and changed on the other", () => {
    const mine = { ...base, prTypes: base.prTypes.slice(0, 1) };
    const theirs = structuredClone(doc);
    theirs.prTypes[1]!.description = "Changed.";
    const r = rebaseRubric(base, mine, theirs);
    expect(r.conflicts.map((c) => c.kind)).toEqual(["type"]);
    expect(r.review.prTypes).toHaveLength(2);
    expect(resolveRubric(r.review, r.conflicts[0]!, "mine").prTypes).toHaveLength(1);
  });

  it("merges categories added on both sides, and keeps this person's order", () => {
    const mine = edit((d) => {
      d.prTypes[0]!.categories.push({ name: "docs", description: "" });
      return d;
    });
    const reordered = { ...mine, prTypes: [mine.prTypes[1]!, mine.prTypes[0]!] };
    const theirs = structuredClone(doc);
    theirs.prTypes[0]!.categories.push({ name: "perf", description: "" });
    const r = rebaseRubric(base, reordered, theirs);
    expect(r.conflicts).toEqual([]);
    const out = toRubricDoc(r.review);
    expect(out.prTypes.map((t) => t.name)).toEqual(["refactor", "feature"]);
    expect(out.prTypes[1]!.categories.map((c) => c.name).sort()).toEqual([
      "correctness",
      "docs",
      "naming",
      "perf",
    ]);
    expect(out.prTypes[1]!.categories[1]!.colour).toBe("blue");
  });

  it("keeps a new type where this person put it, and a type deleted in a reordering", () => {
    const added = { ...base.prTypes[1]!, name: "docs", [RKEY]: 9 };
    const mine = { ...base, prTypes: [base.prTypes[0]!, added, base.prTypes[1]!] };
    const theirs = structuredClone(doc);
    theirs.prTypes.push({ name: "perf", description: "", rubric: "", categories: [] });
    const r = rebaseRubric(base, mine, theirs);
    expect(r.review.prTypes.map((t) => t.name)).toEqual(["feature", "docs", "refactor", "perf"]);
    // Reordered and one deleted here, changed there: the conflict keeps theirs, in its place.
    const swapped = { ...base, prTypes: [base.prTypes[1]!] };
    const changed = structuredClone(doc);
    changed.prTypes[0]!.rubric = "Changed.";
    const s = rebaseRubric(base, { ...swapped, prTypes: [base.prTypes[1]!] }, changed);
    expect(s.conflicts.map((c) => c.kind)).toEqual(["type"]);
    expect(s.review.prTypes.map((t) => t.name).sort()).toEqual(["feature", "refactor"]);
  });

  it("asks about a category both changed differently", () => {
    const mine = edit((d) => {
      d.prTypes[0]!.categories[0]!.description = "Mine.";
      return d;
    });
    const theirs = structuredClone(doc);
    theirs.prTypes[0]!.categories[0]!.description = "Theirs.";
    const r = rebaseRubric(base, mine, theirs);
    expect(r.conflicts.map((c) => c.kind)).toEqual(["category"]);
    const settled = resolveRubric(r.review, r.conflicts[0]!, "mine");
    expect(toRubricDoc(settled).prTypes[0]!.categories[0]!.description).toBe("Mine.");
  });
});