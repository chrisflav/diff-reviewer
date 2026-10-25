import { describe, expect, it } from "vitest";
import type { Repo } from "./api";
import {
  addLogins,
  formProblem,
  loginProblem,
  mergeRepoSettings,
  onlyAutoReviewChanged,
  openConflicts,
  putBody,
  resolveRepoConflict,
  type RepoForm,
} from "./repoSettings";

const form = (over: Partial<RepoForm> = {}): RepoForm => ({
  mode: "staged",
  autoReview: false,
  trustedReviewers: ["alice", "bob"],
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