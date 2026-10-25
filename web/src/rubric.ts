/**
 * A repository's rubric document as the rubric page edits it: its checks, which mirror
 * `Rubric.validate` in Lean; the categories a review may use, which mirror `categoriesFor`; and a
 * three-way merge, for a save that met a newer version.
 *
 * Pure functions only, so that what the page does can be checked without a browser. Like
 * reviews, documents keep the fields this client does not know: every edit spreads what was read.
 */

import type { Category, PrType, RubricDocument } from "./api";
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

/** The fields of a `GET`'s answer that are about the version, not the document. */
const metaFields = ["owner", "name", "version", "createdAt", "documentError"];

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
 * Why the server would refuse category `cat` on a comment, or `null`. `allowed` is
 * `categoriesFor`'s answer (empty: free text); `was` the category the comment had when stored,
 * which the server does not check again — the agent gave it under the rubric it reviewed by.
 */
export function categoryProblem(
  cat: string | undefined,
  allowed: string[],
  was?: string,
): string | null {
  if (cat === undefined) return null;
  if (blankAscii(cat) || charLength(cat) > MAX_CATEGORY_LENGTH)
    return `The category must be 1 to ${MAX_CATEGORY_LENGTH} characters.`;
  if (allowed.length > 0 && !allowed.includes(cat) && cat !== was)
    return `"${cat}" is not a category of the rubric; it is one of ${allowed.join(", ")}.`;
  return null;
}

// Merging. A save refused because the document moved on (409) moves the edits onto the newer
// version: what only one side changed takes that change; what both changed differently is a
// conflict, left at the newer version until the person picks.

export type RubricConflict =
  | { kind: "field"; name: string; mine: unknown; theirs: unknown }
  | { kind: "typeField"; type: number; label: string; name: string; mine: unknown; theirs: unknown }
  | { kind: "type"; type: number; label: string; mine: LocalType | null; theirs: LocalType | null }
  | {
      kind: "category";
      type: number;
      category: number;
      label: string;
      mine: LocalCategory | null;
      theirs: LocalCategory | null;
    };

export function rubricConflictId(c: RubricConflict): string {
  switch (c.kind) {
    case "field":
      return `field:${c.name}`;
    case "typeField":
      return `type:${c.type}:${c.name}`;
    case "type":
      return `type:${c.type}`;
    case "category":
      return `cat:${c.type}:${c.category}`;
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

/** Key `other`'s items by the items of `known` they are: by name, then a rename at one place. */
function alignNamed<T extends { name: string }, L extends T & { [RKEY]: number }>(
  known: L[],
  other: T[],
  fresh: () => number,
  sameRest: (k: L, o: T) => boolean,
): (T & { [RKEY]: number })[] {
  const keys: (number | undefined)[] = other.map(() => undefined);
  const used = new Set<number>();
  other.forEach((o, i) => {
    const k = known.find((x) => !used.has(x[RKEY]) && x.name === o.name);
    if (k !== undefined) {
      keys[i] = k[RKEY];
      used.add(k[RKEY]);
    }
  });
  // A rename: the one unpaired item that says the same as an unpaired one of the other side.
  other.forEach((o, i) => {
    if (keys[i] !== undefined) return;
    const ks = known.filter((x) => !used.has(x[RKEY]) && sameRest(x, o));
    const k = ks[0];
    if (ks.length !== 1 || k === undefined) return;
    if (other.filter((x, j) => keys[j] === undefined && sameRest(k, x)).length !== 1) return;
    keys[i] = k[RKEY];
    used.add(k[RKEY]);
  });
  return other.map((o, i) => ({ ...o, [RKEY]: keys[i] ?? fresh() }));
}

function withoutName(x: object): Record<string, unknown> {
  const out = strip(x);
  delete out.name;
  delete out.categories;
  return out;
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

/**
 * The order of the merged items: this person's, when they reordered (the other side's new items
 * after it), else the other side's. Either way, an item new on the side whose order is not taken
 * goes in after the item it follows there, so that a type added and moved stays where it was put;
 * so does one deleted there, which a conflict may bring back. Keys only.
 */
function mergeOrder(base: number[], mine: number[], theirs: number[]): number[] {
  const inBase = new Set(base);
  const keptMine = mine.filter((k) => inBase.has(k));
  const reordered = !same(
    keptMine,
    base.filter((k) => keptMine.includes(k)),
  );
  const [first, second] = reordered ? [mine, theirs] : [theirs, mine];
  const out = [...first];
  second.forEach((k, i) => {
    if (out.includes(k)) return;
    // After the nearest item before it that the merge has; at the start if none.
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
 * Key `d`'s types and categories by those of `base` they are: by name, or a rename where all
 * else is the same. New ones get keys from `fresh`.
 */
export function alignRubric(base: LocalRubric, d: RubricDoc, fresh: () => number): LocalRubric {
  const types = alignNamed<PrType, LocalType>(base.prTypes, d.prTypes, fresh, (k, o) =>
    same(withoutName(k), withoutName(o)),
  ).map((t) => {
    const bt = base.prTypes.find((x) => x[RKEY] === t[RKEY]);
    return {
      ...t,
      categories: alignNamed<Category, LocalCategory>(
        bt?.categories ?? [],
        t.categories ?? [],
        fresh,
        (k, o) => same(withoutName(k), withoutName(o)),
      ),
    } as LocalType;
  });
  return { ...d, prTypes: types };
}

/**
 * Move this person's edits (`mine`, made to `base`) onto a newer version (`theirs`). Types and
 * categories are matched by name (a rename by everything else being the same); a type's fields
 * and its categories merge on their own, and a type or category one side deleted and the other
 * changed is a conflict. Nothing the other side did is undone without the person choosing.
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

  const byKey = <X extends { [RKEY]: number }>(xs: X[]) => new Map(xs.map((x) => [x[RKEY], x]));
  const [bT, mT, tT] = [byKey(base.prTypes), byKey(mine.prTypes), byKey(theirs.prTypes)];
  const types = new Map<number, LocalType>();
  const order = mergeOrder(
    base.prTypes.map((t) => t[RKEY]),
    mine.prTypes.map((t) => t[RKEY]),
    theirs.prTypes.map((t) => t[RKEY]),
  );
  for (const key of order) {
    const [b, m, t] = [bT.get(key), mT.get(key) ?? null, tT.get(key) ?? null];
    const label = (m ?? t ?? b)?.name ?? "a type";
    if (b === undefined) {
      // New on one side only: keys are fresh per side.
      const x = m ?? t;
      if (x !== null) types.set(key, x);
      continue;
    }
    if (m !== null && same(m, b)) {
      if (t !== null) types.set(key, t);
      continue;
    }
    if (t !== null && same(t, b)) {
      if (m !== null) types.set(key, m);
      continue;
    }
    if (m === null && t === null) continue;
    if (m === null || t === null) {
      conflicts.push({ kind: "type", type: key, label, mine: m, theirs: t });
      if (t !== null) types.set(key, t);
      continue;
    }
    // Both changed it: field by field, and its categories as the types are.
    const [tf, tclash] = mergeFields(b, m, t, ["categories"]);
    for (const name of tclash)
      conflicts.push({ kind: "typeField", type: key, label, name, mine: m[name], theirs: t[name] });
    const [bC, mC, tC] = [byKey(b.categories), byKey(m.categories), byKey(t.categories)];
    const cats: LocalCategory[] = [];
    for (const ck of mergeOrder(
      b.categories.map((c) => c[RKEY]),
      m.categories.map((c) => c[RKEY]),
      t.categories.map((c) => c[RKEY]),
    )) {
      const [bc, mc, tc] = [bC.get(ck), mC.get(ck) ?? null, tC.get(ck) ?? null];
      if (bc === undefined || (mc !== null && same(mc, bc))) {
        const x = bc === undefined ? (mc ?? tc) : tc;
        if (x !== null) cats.push(x);
        continue;
      }
      if (tc !== null && same(tc, bc)) {
        if (mc !== null) cats.push(mc);
        continue;
      }
      if (mc === null && tc === null) continue;
      if (mc !== null && tc !== null) {
        const [cf, cclash] = mergeFields(bc, mc, tc, []);
        if (cclash.length === 0) {
          cats.push({ ...cf, [RKEY]: ck } as LocalCategory);
          continue;
        }
      }
      conflicts.push({
        kind: "category",
        type: key,
        category: ck,
        label: `${label}: ${(mc ?? tc ?? bc).name}`,
        mine: mc,
        theirs: tc,
      });
      if (tc !== null) cats.push(tc);
    }
    types.set(key, { ...tf, categories: cats, [RKEY]: key } as LocalType);
  }
  const prTypes = order.flatMap((k) => {
    const t = types.get(k);
    return t === undefined ? [] : [t];
  });
  return { review: { ...fields, prTypes } as LocalRubric, base: theirs, conflicts };
}

export type RubricPick = "mine" | "theirs";

/** `r` with a conflict settled one way. Picking again settles it the other way. */
export function resolveRubric(r: LocalRubric, c: RubricConflict, pick: RubricPick): LocalRubric {
  const v = pick === "mine" ? c.mine : c.theirs;
  if (c.kind === "field") {
    const out: LocalRubric = { ...r };
    if (v === undefined) delete out[c.name];
    else out[c.name] = v;
    return out;
  }
  if (c.kind === "type") {
    const keep = v as LocalType | null;
    const at = r.prTypes.findIndex((t) => t[RKEY] === c.type);
    const prTypes = r.prTypes.filter((t) => t[RKEY] !== c.type);
    if (keep !== null) prTypes.splice(at < 0 ? prTypes.length : at, 0, keep);
    return { ...r, prTypes };
  }
  return {
    ...r,
    prTypes: r.prTypes.map((t) => {
      if (t[RKEY] !== c.type) return t;
      if (c.kind === "typeField") {
        const out: LocalType = { ...t };
        if (v === undefined) delete out[c.name];
        else out[c.name] = v;
        return out;
      }
      const keep = v as LocalCategory | null;
      const at = t.categories.findIndex((x) => x[RKEY] === c.category);
      const categories = t.categories.filter((x) => x[RKEY] !== c.category);
      if (keep !== null) categories.splice(at < 0 ? categories.length : at, 0, keep);
      return { ...t, categories };
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