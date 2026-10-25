/**
 * A repository's rubric document as the rubric page edits it: its checks, which mirror
 * `Rubric.validate` in Lean; the categories a review may use, which mirror `categoriesFor`; and a
 * three-way merge, for a save that met a newer version.
 *
 * Pure functions only, so that what the page does can be checked without a browser. Like
 * reviews, documents keep the fields this client does not know: every edit spreads what was read.
 */

import type { Category, InlineComment, PrType, Review, RubricDocument } from "./api";
import { MAX_CATEGORY_LENGTH, same } from "./review";
import { blankAscii, charLength, utf8Bytes } from "./text";

/** The most pull request types a document may name, and categories a type may. */
export const MAX_PR_TYPES = 50;
export const MAX_CATEGORIES = 50;
/** The longest name of a type or a category, in characters. */
export const MAX_NAME_LENGTH = 100;
/** The longest rubric, default or a type's, in bytes of UTF-8. */
export const MAX_RUBRIC_BYTES = 65536;

/**
 * The key a type or category is known by while the page edits it: a symbol, as a comment's is,
 * so that it can never clash with a field of the document and `JSON.stringify` drops it.
 */
export const RKEY: unique symbol = Symbol("rubric key");

export interface LocalCategory extends Category {
  [RKEY]: number;
}

export interface LocalType extends PrType {
  [RKEY]: number;
  categories: LocalCategory[];
}

/** The document alone: what a `PUT` sends beside the version. */
export interface RubricDoc {
  defaultRubric: string;
  prTypes: PrType[];
  [field: string]: unknown;
}

export interface LocalRubric {
  defaultRubric: string;
  prTypes: LocalType[];
  [field: string]: unknown;
}

/**
 * The fields of a `GET`'s answer that are about the version, not the document: what it was
 * derived from among them, which the server records and ignores when sent back.
 */
const metaFields = [
  "owner",
  "name",
  "version",
  "createdAt",
  "documentError",
  "derivedFrom",
  "derivedFromPulls",
];

/** The document a version holds, or `null` when this build cannot read it. */
export function documentOf(v: RubricDocument): RubricDoc | null {
  if (v.documentError !== null || v.defaultRubric === null || v.prTypes === null) return null;
  const out: Record<string, unknown> = { ...v };
  for (const f of metaFields) delete out[f];
  return out as RubricDoc;
}

/** Key `d`'s types and categories, by position, or by `keys` where given (stored edits). */
export function toLocalRubric(d: RubricDoc, keys?: Frozen["keys"]): LocalRubric {
  return {
    ...d,
    prTypes: d.prTypes.map((t, i) => ({
      ...t,
      categories: (t.categories ?? []).map((c, j) => ({ ...c, [RKEY]: keys?.cats[i]?.[j] ?? j })),
      [RKEY]: keys?.types[i] ?? i,
    })),
  };
}

/** The document as the API takes it: every field it came with, the keys dropped. */
export function toRubricDoc(r: LocalRubric): RubricDoc {
  return {
    ...r,
    prTypes: r.prTypes.map((t) => {
      const out: Partial<LocalType> = { ...t };
      delete out[RKEY];
      const categories = t.categories.map((c) => {
        const o: Partial<LocalCategory> & Category = { ...c };
        delete o[RKEY];
        return o as Category;
      });
      return { ...out, categories } as PrType;
    }),
  };
}

export function sameRubric(a: LocalRubric, b: LocalRubric): boolean {
  return same(toRubricDoc(a), toRubricDoc(b));
}

/** A counter past every key in `rs`, for types and categories new to all of them. */
export function freshRubricKeys(...rs: LocalRubric[]): () => number {
  let next = 0;
  for (const r of rs)
    for (const t of r.prTypes) {
      next = Math.max(next, t[RKEY] + 1);
      for (const c of t.categories) next = Math.max(next, c[RKEY] + 1);
    }
  return () => next++;
}

/** A local document as JSON can hold it: the keys beside the document, not in it. */
export interface Frozen {
  doc: RubricDoc;
  keys: { types: number[]; cats: number[][] };
}

export function freezeRubric(r: LocalRubric): Frozen {
  return {
    doc: toRubricDoc(r),
    keys: {
      types: r.prTypes.map((t) => t[RKEY]),
      cats: r.prTypes.map((t) => t.categories.map((c) => c[RKEY])),
    },
  };
}

export function thawRubric(f: unknown): LocalRubric | null {
  if (typeof f !== "object" || f === null) return null;
  const { doc, keys } = f as { doc?: unknown; keys?: unknown };
  const d = parseRubricDoc(doc);
  if (d === null || typeof keys !== "object" || keys === null) return null;
  const { types, cats } = keys as { types?: unknown; cats?: unknown };
  const ints = (x: unknown): x is number[] => Array.isArray(x) && x.every(Number.isInteger);
  if (!ints(types) || !Array.isArray(cats) || types.length !== d.prTypes.length) return null;
  if (!d.prTypes.every((t, i) => ints(cats[i]) && cats[i].length === t.categories.length))
    return null;
  return toLocalRubric(d, { types, cats: cats as number[][] });
}

/** A stored document read back: the shape the editor needs, or `null`. */
function parseRubricDoc(j: unknown): RubricDoc | null {
  if (!isObject(j) || typeof j.defaultRubric !== "string" || !Array.isArray(j.prTypes)) return null;
  for (const t of j.prTypes as unknown[]) {
    if (!isObject(t) || typeof t.name !== "string") return null;
    if (typeof t.description !== "string" || typeof t.rubric !== "string") return null;
    if (!Array.isArray(t.categories)) return null;
    for (const c of t.categories as unknown[])
      if (!isObject(c) || typeof c.name !== "string" || typeof c.description !== "string")
        return null;
  }
  return j as RubricDoc;
}

function isObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

/** Where a problem is, for the editor to mark the field; `type`/`category` are indices. */
export interface RubricProblem {
  message: string;
  type?: number;
  category?: number;
  field: "defaultRubric" | "prTypes" | "name" | "rubric" | "categories";
}

/**
 * Every reason the server would refuse `d`, in the order `Rubric.validate` checks them: its first
 * is the one the server answers with. Names are compared exactly, as the server does: "Docs" and
 * "docs" are two categories.
 */
export function rubricProblems(d: RubricDoc): RubricProblem[] {
  const out: RubricProblem[] = [];
  const name = (what: string, n: string, at: Omit<RubricProblem, "message" | "field">) => {
    if (blankAscii(n)) out.push({ message: `${what} has an empty name`, field: "name", ...at });
    else if (charLength(n) > MAX_NAME_LENGTH)
      out.push({
        message: `${what}'s name is longer than ${MAX_NAME_LENGTH} characters`,
        field: "name",
        ...at,
      });
  };
  if (utf8Bytes(d.defaultRubric) > MAX_RUBRIC_BYTES)
    out.push({
      message: `the default rubric is longer than ${MAX_RUBRIC_BYTES} bytes`,
      field: "defaultRubric",
    });
  if (d.prTypes.length > MAX_PR_TYPES)
    out.push({
      message: `the document names ${d.prTypes.length} pull request types; at most ${MAX_PR_TYPES}`,
      field: "prTypes",
    });
  d.prTypes.forEach((t, i) => {
    name(`pull request type ${i + 1}`, t.name, { type: i });
    if (d.prTypes.filter((u) => u.name === t.name).length > 1)
      out.push({
        message: `two pull request types are called '${t.name}'`,
        field: "name",
        type: i,
      });
    if (utf8Bytes(t.rubric) > MAX_RUBRIC_BYTES)
      out.push({
        message: `the rubric of '${t.name}' is longer than ${MAX_RUBRIC_BYTES} bytes`,
        field: "rubric",
        type: i,
      });
    if (t.categories.length > MAX_CATEGORIES)
      out.push({
        message: `'${t.name}' names ${t.categories.length} categories; at most ${MAX_CATEGORIES}`,
        field: "categories",
        type: i,
      });
    t.categories.forEach((c, j) => {
      name(`category ${j + 1} of '${t.name}'`, c.name, { type: i, category: j });
      if (t.categories.filter((x) => x.name === c.name).length > 1)
        out.push({
          message: `'${t.name}' has two categories called '${c.name}'`,
          field: "name",
          type: i,
          category: j,
        });
    });
  });
  return out;
}

/**
 * The categories a comment of a review of type `prType` may be filed under; mirrors
 * `Rubric.categoriesFor`. The type's, when the document names it — none, for a type that lists
 * none, and then a category is free text. A review of no type the document names (a job reviewed
 * by hand) may use any category of the document, or free text if it names none. Empty means free
 * text.
 */
export function categoriesFor(d: RubricDoc, prType: string | null): string[] {
  const t = prType === null ? undefined : d.prTypes.find((x) => x.name === prType);
  if (t !== undefined) return t.categories.map((c) => c.name);
  const out: string[] = [];
  for (const x of d.prTypes)
    for (const c of x.categories) if (!out.includes(c.name)) out.push(c.name);
  return out;
}

/**
 * Which version of the repository's document a job's comments are checked against, as the server
 * picks it (`rubricOfJob`): the job's `rubricVersion` — 0 is none at all — or, for a job from
 * before rubrics (`null`), the current one.
 */
export function rubricVersionOfJob(rubricVersion: number | null): "none" | "current" | number {
  if (rubricVersion === 0) return "none";
  if (rubricVersion === null) return "current";
  return rubricVersion;
}

/**
 * Why the server would refuse category `cat` on a comment it checks, or `null`. `allowed` is
 * `categoriesFor`'s answer (empty: free text).
 */
export function categoryProblem(cat: string | undefined, allowed: string[]): string | null {
  if (cat === undefined) return null;
  if (blankAscii(cat) || charLength(cat) > MAX_CATEGORY_LENGTH)
    return `The category must be 1 to ${MAX_CATEGORY_LENGTH} characters.`;
  if (allowed.length > 0 && !allowed.includes(cat))
    return `"${cat}" is not a category of the rubric; it is one of ${allowed.join(", ")}.`;
  return null;
}

/**
 * The categories the stored review's comments have, by comment id: what the server takes a
 * comment's category to be unchanged from. A comment without an id is always checked.
 */
export function storedCategories(r: Review | null): Map<string, string | undefined> {
  const out = new Map<string, string | undefined>();
  for (const c of r?.comments ?? []) if (typeof c.id === "string") out.set(c.id, c.category);
  return out;
}

/** Why the server would refuse comment `c`'s category, checked as `putReview` checks it. */
export function commentCategoryProblem(
  c: InlineComment,
  allowed: string[],
  stored: Map<string, string | undefined>,
): string | null {
  const unchanged = typeof c.id === "string" && stored.has(c.id) && stored.get(c.id) === c.category;
  return unchanged ? null : categoryProblem(c.category, allowed);
}

/** The first comment of `r` whose category the server would refuse, said as it would say it. */
export function reviewCategoryProblem(
  r: Review,
  allowed: string[],
  stored: Map<string, string | undefined>,
): string | null {
  for (const [i, c] of r.comments.entries()) {
    const p = commentCategoryProblem(c, allowed, stored);
    if (p !== null) return `Comment ${i + 1}: ${p}`;
  }
  return null;
}

// Merging. A save refused because the document moved on (409) moves the edits onto the newer
// version: what only one side changed takes that change; what both changed differently is a
// conflict, left at the newer version until the person picks.
//
// Types and categories are matched by name only. A rename is a deletion and an addition: there is
// no guessing which item another is, so an edit never lands on an item it was not made to.

type Keyed = { [RKEY]: number };

export type RubricConflict =
  | { kind: "field"; name: string; mine: unknown; theirs: unknown }
  | { kind: "typeField"; type: number; label: string; name: string; mine: unknown; theirs: unknown }
  | {
      kind: "type";
      type: number;
      label: string;
      mine: LocalType | null;
      theirs: LocalType | null;
      /** The merged order of the types, for putting one back where it was. */
      order: number[];
    }
  | {
      kind: "categoryField";
      type: number;
      category: number;
      label: string;
      name: string;
      mine: unknown;
      theirs: unknown;
    }
  | {
      kind: "category";
      type: number;
      category: number;
      label: string;
      mine: LocalCategory | null;
      theirs: LocalCategory | null;
      order: number[];
    }
  | {
      /** Both sides reordered the same items differently; `type` null is the types themselves. */
      kind: "order";
      type: number | null;
      label: string;
      mine: number[];
      theirs: number[];
      mineNames: string[];
      theirsNames: string[];
    };

export function rubricConflictId(c: RubricConflict): string {
  switch (c.kind) {
    case "field":
      return `field:${c.name}`;
    case "typeField":
      return `type:${c.type}:${c.name}`;
    case "type":
      return `type:${c.type}`;
    case "categoryField":
      return `cat:${c.type}:${c.category}:${c.name}`;
    case "category":
      return `cat:${c.type}:${c.category}`;
    case "order":
      return c.type === null ? "order" : `order:${c.type}`;
  }
}

export interface RubricRebased {
  review: LocalRubric;
  /** `theirs`, keyed like the edits: what the edits are now changes to. */
  base: LocalRubric;
  conflicts: RubricConflict[];
}

function strip(x: object): Record<string, unknown> {
  const out: { [RKEY]?: number; [field: string]: unknown } = { ...x };
  delete out[RKEY];
  return out;
}

/** Key `other`'s items by the items of `known` with their names; the rest are new. */
function alignNamed<T extends { name: string }>(
  known: (T & Keyed)[],
  other: T[],
  fresh: () => number,
): (T & Keyed)[] {
  const used = new Set<number>();
  return other.map((o) => {
    const k = known.find((x) => !used.has(x[RKEY]) && x.name === o.name);
    if (k === undefined) return { ...o, [RKEY]: fresh() };
    used.add(k[RKEY]);
    return { ...o, [RKEY]: k[RKEY] };
  });
}

/** Three-way merge of the fields of an object; answers the merge and the names both changed. */
function mergeFields(
  base: Record<string, unknown>,
  mine: Record<string, unknown>,
  theirs: Record<string, unknown>,
  skip: string[],
): [Record<string, unknown>, string[]] {
  const out: Record<string, unknown> = { ...theirs };
  const clashes: string[] = [];
  const names = new Set([...Object.keys(base), ...Object.keys(mine), ...Object.keys(theirs)]);
  for (const name of names) {
    if (skip.includes(name)) continue;
    const [b, m, t] = [base[name], mine[name], theirs[name]];
    let v = t;
    if (same(t, b)) v = m;
    else if (!same(m, b) && !same(m, t)) clashes.push(name);
    if (v === undefined) delete out[name];
    else out[name] = v;
  }
  return [out, clashes];
}

/** `first`, with each key of `second` it lacks put in after the nearest key before it there. */
function interleave(first: number[], second: number[]): number[] {
  const out = [...first];
  second.forEach((k, i) => {
    if (out.includes(k)) return;
    let at = 0;
    for (let j = i - 1; j >= 0; j--) {
      const p = out.indexOf(second[j] as number);
      if (p >= 0) {
        at = p + 1;
        break;
      }
    }
    out.splice(at, 0, k);
  });
  return out;
}

/**
 * The order of the merged items, and whether both sides reordered the same items differently:
 * then the other side's order is taken and the person is asked. Otherwise the order of the side
 * that reordered (the other side's when neither did), with the items new or deleted on the other
 * side put in after the item they follow there. Keys only.
 */
function mergeOrder(
  base: number[],
  mine: number[],
  theirs: number[],
): { order: number[]; clash: boolean } {
  const reordered = (xs: number[]) => {
    const kept = xs.filter((k) => base.includes(k));
    return !same(
      kept,
      base.filter((k) => kept.includes(k)),
    );
  };
  const [rm, rt] = [reordered(mine), reordered(theirs)];
  const shared = (xs: number[]) =>
    xs.filter((k) => base.includes(k) && mine.includes(k) && theirs.includes(k));
  const clash = rm && rt && !same(shared(mine), shared(theirs));
  const [first, second] = rm && !rt ? [mine, theirs] : [theirs, mine];
  return { order: interleave(first, second), clash };
}

/** `xs` in `order`; items it does not name keep their place after the item they followed. */
export function applyOrder<T extends Keyed>(xs: T[], order: number[]): T[] {
  const keys = interleave(
    order.filter((k) => xs.some((x) => x[RKEY] === k)),
    xs.map((x) => x[RKEY]),
  );
  return keys.flatMap((k) => xs.filter((x) => x[RKEY] === k));
}

/** `xs` with `item` put back where `order` says it goes, among the items there are. */
function putBack<T extends Keyed>(xs: T[], item: T, order: number[]): T[] {
  const out = xs.filter((x) => x[RKEY] !== item[RKEY]);
  const at = order.indexOf(item[RKEY]);
  let i = 0;
  for (let j = at - 1; j >= 0; j--) {
    const p = out.findIndex((x) => x[RKEY] === order[j]);
    if (p >= 0) {
      i = p + 1;
      break;
    }
  }
  out.splice(i, 0, item);
  return out;
}

/**
 * Three-way merge of a list of keyed items. Items both sides added alike are one. Items both added
 * with one name but not alike are one too, as names are matched, and `added` says what to do with
 * them: they are never two items of the same name. `item` merges one item that is in the base
 * (`b`) and on either side; a new one is taken as it is.
 */
function mergeList<T extends Keyed & { name: string }>(
  base: T[],
  mineIn: T[],
  theirs: T[],
  item: (key: number, b: T, m: T | null, t: T | null, order: number[]) => T | null,
  added: (key: number, m: T, t: T, order: number[]) => T,
  onOrderClash: (mine: T[], theirs: T[]) => void,
): T[] {
  const inBase = new Set(base.map((x) => x[RKEY]));
  const theirNew = theirs.filter((x) => !inBase.has(x[RKEY]));
  const taken = new Set<number>();
  // Their new items that mine has under the same name, not alike: one item, which `added` merges.
  const namesakes = new Set<number>();
  const mine = mineIn.map((m) => {
    if (inBase.has(m[RKEY])) return m;
    const free = theirNew.filter((t) => !taken.has(t[RKEY]));
    const twin = free.find((t) => same(strip(t), strip(m))) ?? free.find((t) => t.name === m.name);
    if (twin === undefined) return m;
    taken.add(twin[RKEY]);
    if (same(strip(twin), strip(m))) return twin;
    namesakes.add(twin[RKEY]);
    return { ...m, [RKEY]: twin[RKEY] };
  });
  const keys = (xs: T[]) => xs.map((x) => x[RKEY]);
  const { order, clash } = mergeOrder(keys(base), keys(mine), keys(theirs));
  if (clash) onOrderClash(mine, theirs);
  const by = (xs: T[]) => new Map(xs.map((x) => [x[RKEY], x]));
  const [bm, mm, tm] = [by(base), by(mine), by(theirs)];
  return order.flatMap((k) => {
    const [b, m, t] = [bm.get(k), mm.get(k) ?? null, tm.get(k) ?? null];
    const out =
      b !== undefined
        ? item(k, b, m, t, order)
        : namesakes.has(k) && m !== null && t !== null
          ? added(k, m, t, order)
          : (t ?? m);
    return out === null ? [] : [out];
  });
}

/**
 * Key `d`'s types and categories by those of `base` with the same names. New ones get keys from
 * `fresh`.
 */
export function alignRubric(base: LocalRubric, d: RubricDoc, fresh: () => number): LocalRubric {
  const types = alignNamed<PrType>(base.prTypes, d.prTypes, fresh).map((t) => {
    const bt = base.prTypes.find((x) => x[RKEY] === t[RKEY]);
    return {
      ...t,
      categories: alignNamed<Category>(bt?.categories ?? [], t.categories ?? [], fresh),
    } as LocalType;
  });
  return { ...d, prTypes: types };
}

/**
 * Move this person's edits (`mine`, made to `base`) onto a newer version (`theirs`). A type's
 * fields and its categories merge on their own, a category's fields too; a type or category one
 * side deleted and the other changed, a field both changed differently and an order both changed
 * differently are conflicts, left at their version until the person picks. Nothing the other side
 * did is undone without the person choosing.
 */
export function rebaseRubric(
  base: LocalRubric,
  mine: LocalRubric,
  theirsDoc: RubricDoc,
): RubricRebased {
  const theirs = alignRubric(base, theirsDoc, freshRubricKeys(base, mine));
  const conflicts: RubricConflict[] = [];
  const [fields, clashes] = mergeFields(base, mine, theirs, ["prTypes"]);
  for (const name of clashes)
    conflicts.push({ kind: "field", name, mine: mine[name], theirs: theirs[name] });
  const names = (xs: { name: string }[]) => xs.map((x) => x.name);
  const keys = (xs: Keyed[]) => xs.map((x) => x[RKEY]);

  const prTypes = mergeList<LocalType>(
    base.prTypes,
    mine.prTypes,
    theirs.prTypes,
    (key, b, m, t, order) => {
      if (m !== null && same(m, b)) return t;
      if (t !== null && same(t, b)) return m;
      if (m === null && t === null) return null;
      const label = (m ?? t ?? b).name;
      if (m === null || t === null) {
        conflicts.push({ kind: "type", type: key, label, mine: m, theirs: t, order });
        return t;
      }
      const [tf, tclash] = mergeFields(b, m, t, ["categories"]);
      for (const name of tclash)
        conflicts.push({
          kind: "typeField",
          type: key,
          label,
          name,
          mine: m[name],
          theirs: t[name],
        });
      const categories = mergeList<LocalCategory>(
        b.categories,
        m.categories,
        t.categories,
        (ck, bc, mc, tc, corder) => {
          if (mc !== null && same(mc, bc)) return tc;
          if (tc !== null && same(tc, bc)) return mc;
          if (mc === null && tc === null) return null;
          const clabel = `${label}: ${(mc ?? tc ?? bc).name}`;
          if (mc === null || tc === null) {
            conflicts.push({
              kind: "category",
              type: key,
              category: ck,
              label: clabel,
              mine: mc,
              theirs: tc,
              order: corder,
            });
            return tc;
          }
          const [cf, cclash] = mergeFields(bc, mc, tc, []);
          for (const name of cclash)
            conflicts.push({
              kind: "categoryField",
              type: key,
              category: ck,
              label: clabel,
              name,
              mine: mc[name],
              theirs: tc[name],
            });
          return { ...cf, [RKEY]: ck } as LocalCategory;
        },
        (ck, mc, tc, corder) => {
          conflicts.push({
            kind: "category",
            type: key,
            category: ck,
            label: `${label}: ${tc.name}`,
            mine: mc,
            theirs: tc,
            order: corder,
          });
          return tc;
        },
        (mc, tc) =>
          conflicts.push({
            kind: "order",
            type: key,
            label: `the categories of ${label}`,
            mine: keys(mc),
            theirs: keys(tc),
            mineNames: names(mc),
            theirsNames: names(tc),
          }),
      );
      return { ...tf, categories, [RKEY]: key } as LocalType;
    },
    (key, m, t, order) => {
      conflicts.push({ kind: "type", type: key, label: t.name, mine: m, theirs: t, order });
      return t;
    },
    (mt, tt) =>
      conflicts.push({
        kind: "order",
        type: null,
        label: "the order of the types",
        mine: keys(mt),
        theirs: keys(tt),
        mineNames: names(mt),
        theirsNames: names(tt),
      }),
  );
  return { review: { ...fields, prTypes } as LocalRubric, base: theirs, conflicts };
}

export type RubricPick = "mine" | "theirs";

/** Field `name` of `x` set to `v`, or removed when `v` is undefined. */
function setField<T extends object>(x: T, name: string, v: unknown): T {
  const out = { ...x } as Record<string, unknown>;
  if (v === undefined) delete out[name];
  else out[name] = v;
  return out as T;
}

/** `r` with a conflict settled one way. Picking again settles it the other way. */
export function resolveRubric(r: LocalRubric, c: RubricConflict, pick: RubricPick): LocalRubric {
  if (c.kind === "field") return setField(r, c.name, pick === "mine" ? c.mine : c.theirs);
  if (c.kind === "order" && c.type === null)
    return { ...r, prTypes: applyOrder(r.prTypes, pick === "mine" ? c.mine : c.theirs) };
  if (c.kind === "type") {
    const keep = pick === "mine" ? c.mine : c.theirs;
    if (keep === null) return { ...r, prTypes: r.prTypes.filter((t) => t[RKEY] !== c.type) };
    const at = r.prTypes.findIndex((t) => t[RKEY] === c.type);
    if (at >= 0) return { ...r, prTypes: r.prTypes.map((t, i) => (i === at ? keep : t)) };
    return { ...r, prTypes: putBack(r.prTypes, keep, c.order) };
  }
  return {
    ...r,
    prTypes: r.prTypes.map((t) => {
      if (t[RKEY] !== c.type) return t;
      switch (c.kind) {
        case "typeField":
          return setField(t, c.name, pick === "mine" ? c.mine : c.theirs);
        case "order":
          return {
            ...t,
            categories: applyOrder(t.categories, pick === "mine" ? c.mine : c.theirs),
          };
        case "categoryField":
          return {
            ...t,
            categories: t.categories.map((x) =>
              x[RKEY] === c.category ? setField(x, c.name, pick === "mine" ? c.mine : c.theirs) : x,
            ),
          };
        case "category": {
          const keep = pick === "mine" ? c.mine : c.theirs;
          if (keep === null)
            return { ...t, categories: t.categories.filter((x) => x[RKEY] !== c.category) };
          const at = t.categories.findIndex((x) => x[RKEY] === c.category);
          if (at >= 0)
            return { ...t, categories: t.categories.map((x, i) => (i === at ? keep : x)) };
          return { ...t, categories: putBack(t.categories, keep, c.order) };
        }
      }
    }),
  };
}

/** Move item `i` of `xs` by `by` places, if it can; a new array. */
export function move<T>(xs: T[], i: number, by: number): T[] {
  const j = i + by;
  if (i < 0 || i >= xs.length || j < 0 || j >= xs.length) return xs;
  const out = [...xs];
  const [x] = out.splice(i, 1);
  out.splice(j, 0, x as T);
  return out;
}