import { describe, expect, it } from "vitest";
import type { Repo } from "./api";
import {
  addLogins,
  evalShareProblem,
  formOf,
  formProblem,
  MAX_STYLE_NOTES_BYTES,
  notesProblem,
  loginProblem,
  mergeRepoSettings,
  onlyAutoReviewChanged,
  openConflicts,
  putBody,
  resolveRepoConflict,
  saveRefusal,
  type RepoForm,
} from "./repoSettings";

const form = (over: Partial<RepoForm> = {}): RepoForm => ({
  mode: "staged",
  autoReview: false,
  trustedReviewers: ["alice", "bob"],
  styleNotes: "",
  evalShare: 50,
  ...over,
});

describe("mergeRepoSettings", () => {
  it("keeps the other write's changes where this page changed nothing", () => {
    const base = form();
    const theirs = form({ mode: "direct", trustedReviewers: ["alice", "bob", "carol"] });
    const m = mergeRepoSettings(base, base, theirs);
    expect(m.conflicts).toEqual([]);
    expect(m.form).toEqual(theirs);
  });

  it("merges the trusted reviewers as a set: both sides' additions and removals", () => {
    const base = form({ trustedReviewers: ["alice", "bob", "dan"] });
    const mine = form({ trustedReviewers: ["alice", "dan", "erin"] }); // - bob, + erin
    const theirs = form({ trustedReviewers: ["bob", "dan", "carol"] }); // - alice, + carol
    const m = mergeRepoSettings(base, mine, theirs);
    expect(m.conflicts).toEqual([]);
    expect(m.form.trustedReviewers).toEqual(["dan", "carol", "erin"]);
  });

  it("adds a login both sides added once, compared in lower case", () => {
    const base = form({ trustedReviewers: [] });
    const m = mergeRepoSettings(
      base,
      form({ trustedReviewers: ["Carol"] }),
      form({ trustedReviewers: ["carol"] }),
    );
    expect(m.form.trustedReviewers).toEqual(["carol"]);
  });

  it("takes this page's change of a setting the other write left alone", () => {
    const base = form();
    const m = mergeRepoSettings(base, form({ autoReview: true }), form({ mode: "direct" }));
    expect(m.conflicts).toEqual([]);
    expect(m.form).toEqual(form({ mode: "direct", autoReview: true }));
  });

  it("is no conflict when both changed a setting to the same value", () => {
    const m = mergeRepoSettings(form(), form({ mode: "direct" }), form({ mode: "direct" }));
    expect(m.conflicts).toEqual([]);
  });

  it("never overwrites unasked: a setting both changed differently is a conflict, left at theirs", () => {
    const base = form({ mode: "direct" });
    // A third value is not possible for a boolean, so only the mode can conflict this way; a
    // newer build's third mode stands in for it.
    const theirs = form({ mode: "staged" });
    const mine = form({ mode: "weekly" as RepoForm["mode"] });
    const m = mergeRepoSettings(base, mine, theirs);
    expect(m.conflicts).toEqual([{ field: "mode", mine: "weekly", theirs: "staged" }]);
    expect(m.form.mode).toBe("staged");
    const c = m.conflicts[0];
    if (c === undefined) throw new Error("no conflict");
    expect(resolveRepoConflict(m.form, c, "mine").mode).toBe("weekly");
    expect(resolveRepoConflict(m.form, c, "theirs").mode).toBe("staged");
  });
});

describe("putBody", () => {
  const repo: Repo = {
    owner: "o",
    name: "n",
    mode: "staged",
    autoReview: false,
    trustedReviewers: ["alice"],
    version: 7,
    createdAt: "2026-01-01T00:00:00Z",
    reviewHours: [9, 17],
  };

  it("sends the version read and every setting read, a newer build's among them", () => {
    const b = putBody(repo, form({ trustedReviewers: ["alice", "bob"] }));
    expect(b).toEqual({
      mode: "staged",
      autoReview: false,
      trustedReviewers: ["alice", "bob"],
      version: 7,
      reviewHours: [9, 17],
    });
  });
});

describe("logins", () => {
  it("mirrors validLogin", () => {
    expect(loginProblem("octo-cat")).toBeNull();
    expect(loginProblem("a".repeat(39))).toBeNull();
    expect(loginProblem("a".repeat(40))).not.toBeNull();
    expect(loginProblem("-octo")).not.toBeNull();
    expect(loginProblem("octo-")).not.toBeNull();
    expect(loginProblem("oc--to")).not.toBeNull();
    expect(loginProblem("oc_to")).not.toBeNull();
    expect(loginProblem("ö")).not.toBeNull();
    expect(loginProblem("")).not.toBeNull();
  });

  it("adds several at once, in lower case, without an @, refusing one bad", () => {
    expect(addLogins(["alice"], "@Bob, carol")).toEqual({ list: ["alice", "bob", "carol"] });
    expect("problem" in addLogins(["alice"], "bob x_y")).toBe(true);
    expect(addLogins(["alice"], "Alice")).toEqual({ problem: "Already listed." });
  });

  it("refuses more than 50", () => {
    const fifty = Array.from({ length: 50 }, (_, i) => `u${i}`);
    expect("problem" in addLogins(fifty, "one-more")).toBe(true);
    expect(formProblem(form({ trustedReviewers: [...fifty, "x"] }))).not.toBeNull();
    expect(formProblem(form({ trustedReviewers: fifty }))).toBeNull();
  });
});

describe("onlyAutoReviewChanged", () => {
  const read: Repo = {
    owner: "o",
    name: "n",
    mode: "staged",
    autoReview: false,
    trustedReviewers: ["alice"],
    version: 3,
    createdAt: "x",
    reviewHours: [9, 17],
  };

  it("allows the toggle over a write that changed autoReview alone", () => {
    expect(onlyAutoReviewChanged(read, { ...read, autoReview: true, version: 4 })).toBe(true);
    expect(onlyAutoReviewChanged(read, { ...read, version: 4 })).toBe(true);
  });

  it("refuses it over a write that changed the mode", () => {
    expect(onlyAutoReviewChanged(read, { ...read, mode: "direct", version: 4 })).toBe(false);
  });

  it("refuses it over a write that changed the trusted reviewers or an unknown setting", () => {
    expect(onlyAutoReviewChanged(read, { ...read, trustedReviewers: ["bob"], version: 4 })).toBe(
      false,
    );
    expect(onlyAutoReviewChanged(read, { ...read, reviewHours: [8, 17], version: 4 })).toBe(false);
  });
});

describe("openConflicts", () => {
  it("leaves out the conflicts given a side", () => {
    const cs = [{ field: "mode" as const, mine: "direct" as const, theirs: "staged" as const }];
    expect(openConflicts(cs, {})).toEqual(cs);
    expect(openConflicts(cs, { mode: "mine" })).toEqual([]);
  });
});

describe("style notes and the share held out", () => {
  const repo: Repo = {
    owner: "o",
    name: "n",
    mode: "staged",
    autoReview: false,
    trustedReviewers: ["alice"],
    styleNotes: "Be brief.",
    evalShare: 30,
    styleNotesVersion: 2,
    version: 7,
    createdAt: "2026-01-01T00:00:00Z",
  };

  it("reads them into the form, and defaults them from an older server", () => {
    expect(formOf(repo)).toMatchObject({ styleNotes: "Be brief.", evalShare: 30 });
    const old: Repo = { ...repo };
    delete old.styleNotes;
    delete old.evalShare;
    expect(formOf(old)).toMatchObject({ styleNotes: "", evalShare: 50 });
  });

  it("sends them with the version read, and never the notes' version", () => {
    const b = putBody(repo, { ...formOf(repo), styleNotes: "", evalShare: 0 });
    expect(b).toEqual({
      mode: "staged",
      autoReview: false,
      trustedReviewers: ["alice"],
      styleNotes: "",
      evalShare: 0,
      version: 7,
    });
  });

  it("names the proposal the notes were taken from, when they were", () => {
    const taken = { ...formOf(repo), styleNotes: "Be briefer." };
    expect(putBody(repo, taken, "p1")).toMatchObject({ fromProposal: "p1" });
    expect(putBody(repo, taken)).not.toHaveProperty("fromProposal");
  });

  it("does not name the proposal when the notes saved are those read", () => {
    // Nothing of the proposal is kept, and naming it would accept it, its rubric unwritten.
    expect(putBody(repo, { ...formOf(repo), evalShare: 40 }, "p1")).not.toHaveProperty(
      "fromProposal",
    );
  });

  it("tells a 409 for something else from one for a newer version", () => {
    const why = "'fromProposal': proposal p1 was rejected";
    expect(saveRefusal(7, repo, why)).toBe(why);
    expect(saveRefusal(6, repo, why)).toBeNull();
  });

  it("sends neither to a server that does not know them", () => {
    const old: Repo = { ...repo };
    delete old.styleNotes;
    delete old.evalShare;
    delete old.styleNotesVersion;
    const b = putBody(old, formOf(old));
    expect(b).not.toHaveProperty("styleNotes");
    expect(b).not.toHaveProperty("evalShare");
  });

  it("checks the notes' size in bytes of UTF-8, as the server does", () => {
    expect(notesProblem("x".repeat(MAX_STYLE_NOTES_BYTES))).toBeNull();
    expect(notesProblem("x".repeat(MAX_STYLE_NOTES_BYTES + 1))).not.toBeNull();
    // Two bytes each: half as many characters fit.
    expect(notesProblem("é".repeat(MAX_STYLE_NOTES_BYTES / 2 + 1))).not.toBeNull();
    expect(formProblem(form({ styleNotes: "x".repeat(MAX_STYLE_NOTES_BYTES + 1) }))).toContain(
      "bytes",
    );
  });

  it("takes a whole percent from 0 to 100", () => {
    expect(evalShareProblem(0)).toBeNull();
    expect(evalShareProblem(100)).toBeNull();
    expect(evalShareProblem(101)).not.toBeNull();
    expect(evalShareProblem(-1)).not.toBeNull();
    expect(evalShareProblem(12.5)).not.toBeNull();
    expect(evalShareProblem(Number.NaN)).not.toBeNull();
    expect(formProblem(form({ evalShare: 101 }))).not.toBeNull();
  });

  it("merges the notes as one text: one side's change is taken", () => {
    const base = form({ styleNotes: "a" });
    const m = mergeRepoSettings(
      base,
      form({ styleNotes: "b" }),
      form({ styleNotes: "a", evalShare: 20 }),
    );
    expect(m.conflicts).toEqual([]);
    expect(m.form).toMatchObject({ styleNotes: "b", evalShare: 20 });
  });

  it("asks when both sides changed the notes or the share differently", () => {
    const base = form({ styleNotes: "a", evalShare: 50 });
    const mine = form({ styleNotes: "b", evalShare: 40 });
    const theirs = form({ styleNotes: "c", evalShare: 60 });
    const m = mergeRepoSettings(base, mine, theirs);
    expect(m.conflicts).toEqual([
      { field: "styleNotes", mine: "b", theirs: "c" },
      { field: "evalShare", mine: 40, theirs: 60 },
    ]);
    expect(m.form).toMatchObject({ styleNotes: "c", evalShare: 60 });
    const picked = resolveRepoConflict(m.form, m.conflicts[0]!, "mine");
    expect(picked.styleNotes).toBe("b");
  });
});