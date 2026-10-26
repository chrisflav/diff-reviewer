/**
 * Rubric proposals as the pages use them: what a refused accept means, the body of an accept,
 * where a proposal is rebased, and what adopting one puts into the rubric editor or the settings
 * — the proposal as edits made to the version it was written from, which the editors' three-way
 * merges then move onto the current one.
 *
 * Pure functions and thin calls of `api`, so that the flow can be checked without a browser.
 */

import {
  api,
  ApiError,
  type Repo,
  type RubricDocument,
  type RubricProposal,
  type RubricProposalDiff,
} from "./api";
import { formOf } from "./repoSettings";
import { alignRubric, documentOf, freshRubricKeys, toLocalRubric, toRubricDoc } from "./rubric";
import { rubricStashKey, type RepoEdits, type RubricEdits } from "./stash";

/** The statuses of a proposal job still to write its proposal; mirrors `liveStatuses` in Lean. */
export const LIVE_PROPOSAL_JOB = ["pending", "queued", "running"];

/** Why an accept was refused, as the page explains it. */
export type AcceptRefusal =
  /** The rubric has moved since the proposal's base, or since it was read: rebase in the editor. */
  | { kind: "moved"; baseVersion: number; currentVersion: number; message: string }
  /** Anything else the server refused with a 409: decided already, notes changed or absent. */
  | { kind: "refused"; message: string };

/** What a failed accept was, or null when it was not a refusal (a 401, a network error, …). */
export function acceptRefusal(err: unknown): AcceptRefusal | null {
  if (!(err instanceof ApiError) || err.status !== 409) return null;
  const b = err.body;
  if (typeof b === "object" && b !== null) {
    const { baseVersion, currentVersion } = b as Record<string, unknown>;
    if (Number.isInteger(baseVersion) && Number.isInteger(currentVersion))
      return {
        kind: "moved",
        baseVersion: baseVersion as number,
        currentVersion: currentVersion as number,
        message: err.message,
      };
  }
  return { kind: "refused", message: err.message };
}

/**
 * The body of an accept: the rubric version the person read (the proposal's `currentVersion` as
 * the page loaded it), and the style notes only when asked and the proposal has some. Off unless
 * the person ticks it: accepting the rubric never writes the notes on its own.
 */
export function acceptRequest(
  p: Pick<RubricProposal, "currentVersion" | "proposesStyleNotes">,
  applyStyleNotes = false,
): { version: number; applyStyleNotes: boolean } {
  return { version: p.currentVersion, applyStyleNotes: p.proposesStyleNotes && applyStyleNotes };
}

/** Accept `p` as read: `acceptRequest`'s body, sent. */
export function acceptProposal(p: RubricProposal, applyStyleNotes = false) {
  const r = acceptRequest(p, applyStyleNotes);
  return api.acceptProposal(p.owner, p.name, p.id, r.version, r.applyStyleNotes);
}

/** Where a repository's proposals are. */
export function proposalsPath(owner: string, name: string): string {
  return `/repos/${encodeURIComponent(owner)}/${encodeURIComponent(name)}/proposals`;
}

export function proposalPath(owner: string, name: string, id: string): string {
  return `${proposalsPath(owner, name)}/${encodeURIComponent(id)}`;
}

/** The rubric editor with proposal `id` opened in it, to be rebased and saved. */
export function adoptRubricPath(owner: string, name: string, id: string): string {
  return `/repos/${encodeURIComponent(owner)}/${encodeURIComponent(name)}/rubric?proposal=${encodeURIComponent(id)}`;
}

/** The settings with proposal `id`'s style notes opened in them. */
export function adoptNotesPath(owner: string, name: string, id: string): string {
  return `/repos/${encodeURIComponent(owner)}/${encodeURIComponent(name)}?proposal=${encodeURIComponent(id)}`;
}

/** Why proposal `p` cannot be adopted into the rubric editor, or null. */
export function adoptProblem(p: RubricProposal): string | null {
  if (p.status === "rejected") return `Proposal ${p.id} was rejected; it cannot be adopted.`;
  if (p.document === null || p.document === undefined)
    return `Proposal ${p.id}'s document cannot be read by this version${p.documentError ? `: ${p.documentError}` : "."}`;
  return null;
}

/**
 * Proposal `p` as rubric edits: its document, made to `base`, the version it was written from
 * (null for version 0, no rubric), named by `fromProposal`. Moved onto the current version by the
 * editor's three-way merge, what the proposal changed and the rubric did not since is taken, and
 * where both changed one thing the person picks.
 */
export function adoptionEdits(
  owner: string,
  name: string,
  p: RubricProposal,
  base: RubricDocument | null,
): RubricEdits | string {
  const why = adoptProblem(p);
  if (why !== null) return why;
  const baseDoc = base === null ? { defaultRubric: "", prTypes: [] } : documentOf(base);
  if (baseDoc === null)
    return `Version ${p.baseVersion} of the rubric, which proposal ${p.id} was written from, cannot be read by this version.`;
  const b = toLocalRubric(baseDoc);
  const doc = p.document as NonNullable<RubricProposal["document"]>;
  return {
    repo: rubricStashKey(owner, name),
    version: p.baseVersion,
    base: b,
    doc: alignRubric(b, doc, freshRubricKeys(b)),
    fromProposal: p.id,
  };
}

/** Load proposal `id` and the version it was written from, as `adoptionEdits`. */
export async function loadAdoption(
  owner: string,
  name: string,
  id: string,
): Promise<RubricEdits | string> {
  const p = await api.proposal(owner, name, id);
  const why = adoptProblem(p);
  if (why !== null) return why;
  const base = p.baseVersion === 0 ? null : await api.rubricAt(owner, name, p.baseVersion);
  return adoptionEdits(owner, name, p, base);
}

/** Save rubric edits, naming the proposal they were made from when they were. */
export function saveRubricEdits(owner: string, name: string, e: RubricEdits) {
  return api.putRubrics(owner, name, e.version, toRubricDoc(e.doc), e.fromProposal);
}

/**
 * Proposal `p`'s style notes as settings edits: made to the notes its agent was given (the rest of
 * the settings as `repo` holds them), named by `fromProposal`. Moved onto `repo` by the settings'
 * three-way merge: when the notes have changed since the agent read them, and the proposal changed
 * them too, the person picks.
 */
export function notesAdoptionEdits(repo: Repo, p: RubricProposal): RepoEdits | string {
  if (p.status === "rejected") return `Proposal ${p.id} was rejected; it cannot be adopted.`;
  if (typeof p.styleNotes !== "string") return `Proposal ${p.id} proposes no style notes.`;
  const now = formOf(repo);
  return {
    repo: rubricStashKey(repo.owner, repo.name),
    version: repo.version,
    base: { ...now, styleNotes: p.baseStyleNotes ?? "" },
    form: { ...now, styleNotes: p.styleNotes },
    fromProposal: p.id,
  };
}

/** Whether a proposal's diff changes nothing of the rubric (its style notes aside). */
export function rubricUnchanged(d: RubricProposalDiff): boolean {
  return (
    d.defaultRubric === null &&
    (d.fanout ?? null) === null &&
    d.typesAdded.length === 0 &&
    d.typesRemoved.length === 0 &&
    d.typesChanged.length === 0
  );
}

/** What a proposal changes, counted, for the list and the page's heading. */
export function diffCounts(d: RubricProposalDiff): string {
  const parts: string[] = [];
  if (d.defaultRubric !== null) parts.push("the default rubric");
  // Fan-out multiplies what every review costs: never counted as "no changes".
  if (d.fanout) parts.push(`fan-out turned ${d.fanout.after ? "on" : "off"}`);
  const n = (k: number, one: string, many: string) => `${k} ${k === 1 ? one : many}`;
  if (d.typesAdded.length > 0) parts.push(`${n(d.typesAdded.length, "type", "types")} added`);
  if (d.typesRemoved.length > 0) parts.push(`${n(d.typesRemoved.length, "type", "types")} removed`);
  if (d.typesChanged.length > 0) parts.push(`${n(d.typesChanged.length, "type", "types")} changed`);
  if (d.styleNotes !== null) parts.push("the style notes");
  return parts.length === 0 ? "no changes" : parts.join(", ");
}

// The rationale is markdown an agent wrote, from evidence anyone may have written: it is shown as
// text. A small subset is read by hand — headings, paragraphs, lists, quotes, code, emphasis — and
// every piece of it becomes a text node React escapes. Nothing becomes HTML, and a link is shown
// as its text and its address, never as a link.

export type Inline =
  | { kind: "text"; text: string }
  | { kind: "code"; text: string }
  | { kind: "strong"; children: Inline[] }
  | { kind: "em"; children: Inline[] }
  /** A markdown link, shown as its text and, beside it, its address: never followed. */
  | { kind: "link"; children: Inline[]; target: string };

export type Block =
  | { kind: "heading"; level: number; children: Inline[] }
  | { kind: "paragraph"; children: Inline[] }
  | { kind: "list"; ordered: boolean; items: Inline[][] }
  | { kind: "quote"; children: Inline[] }
  | { kind: "code"; text: string };

/** Whether `c` is whitespace, as `\s` reads it; false past either end. */
function isSpace(c: string | undefined): boolean {
  return c !== undefined && /\s/.test(c);
}

/**
 * The inline parts of `s`: code spans, links, strong and emphasis; everything else is text.
 *
 * Read in one pass, each construct found by a scan forward that a failed attempt remembers: a
 * backtick run with no closer of its length, a `[` with no `]` after it, a `](` with no address
 * and `)` after it, a `**` with no closer — none of these is looked for again further on. The
 * input is an agent's, up to 32 KB of it, and a regular expression tried at each position takes
 * seconds on the wrong one.
 */
export function parseInline(s: string, depth = 0): Inline[] {
  const out: Inline[] = [];
  let text = "";
  const flush = () => {
    if (text !== "") out.push({ kind: "text", text });
    text = "";
  };
  // Backtick run lengths with no run of exactly that length after the last place looked.
  const noCloser = new Set<number>();
  // Where a closing run of exactly `k` backticks is at or after `from`, or -1.
  const closer = (k: number, from: number): number => {
    const run = "`".repeat(k);
    let j = s.indexOf(run, from);
    while (j !== -1) {
      let end = j + k;
      while (s[end] === "`") end++;
      if (end - j === k && s[j - 1] !== "`") return j;
      j = s.indexOf(run, end);
    }
    return -1;
  };
  // The next `]` and the next newline at or after a position, found once and reused until passed.
  let bracket = -2;
  let newline = -2;
  const next = (c: string, from: number, at: number) =>
    at === -1 || at >= from ? at : s.indexOf(c, from);
  // The link's address and its closing `)`, from just after `](`; linear, the alternatives
  // starting with different characters.
  const target = /((?:[^()\s]|\([^()\s]*\))*)\)/y;
  // The `]` whose `(` opened no link: every `[` before it would try the same address again.
  let noTarget = -1;
  // Where a strong span opened by `d` closes, from the earliest place its closer can be: the
  // first `d` after a character that is not whitespace. Remembered as for the brackets.
  const strongAt: Record<string, { from: number; at: number }> = {};
  const strongCloser = (d: string, from: number): number => {
    const memo = strongAt[d];
    if (memo !== undefined && memo.from <= from && (memo.at === -1 || memo.at >= from))
      return memo.at;
    let j = s.indexOf(d, from);
    while (j !== -1 && isSpace(s[j - 1])) j = s.indexOf(d, j + 1);
    strongAt[d] = { from, at: j };
    return j;
  };
  const em = /(\*|_)(?=[^\s*_])([^*_\n]*?[^\s*_])\1(?![*_\w])/y;
  let i = 0;
  while (i < s.length) {
    const c = s[i] as string;
    if (c === "`") {
      let k = 1;
      while (s[i + k] === "`") k++;
      const j = noCloser.has(k) ? -1 : closer(k, i + k);
      if (j === -1) {
        noCloser.add(k);
        text += s.slice(i, i + k);
        i += k;
        continue;
      }
      flush();
      const body = s.slice(i + k, j);
      out.push({ kind: "code", text: body.trim() || body });
      i = j + k;
      continue;
    }
    if (depth < 3 && c === "[") {
      bracket = next("]", i + 1, bracket);
      newline = next("\n", i + 1, newline);
      if (
        bracket > i + 1 &&
        bracket !== noTarget &&
        (newline === -1 || newline > bracket) &&
        s[bracket + 1] === "("
      ) {
        target.lastIndex = bracket + 2;
        const t = target.exec(s);
        if (t === null) noTarget = bracket;
        else {
          flush();
          out.push({
            kind: "link",
            children: parseInline(s.slice(i + 1, bracket), depth + 1),
            target: t[1] as string,
          });
          i = target.lastIndex;
          continue;
        }
      }
    }
    if (depth < 3 && (c === "*" || c === "_") && s[i + 1] === c) {
      const d = c + c;
      if (s[i + 2] !== undefined && !isSpace(s[i + 2])) {
        const j = strongCloser(d, i + 3);
        if (j !== -1) {
          flush();
          out.push({ kind: "strong", children: parseInline(s.slice(i + 2, j), depth + 1) });
          i = j + 2;
          continue;
        }
      }
    }
    if (depth < 3 && (c === "*" || c === "_") && (i === 0 || !/\w/.test(s[i - 1] as string))) {
      em.lastIndex = i;
      const m = em.exec(s);
      if (m !== null) {
        flush();
        out.push({ kind: "em", children: parseInline(m[2] as string, depth + 1) });
        i = em.lastIndex;
        continue;
      }
    }
    text += c;
    i++;
  }
  flush();
  return out;
}

/** A heading's text without the closing run of `#`s and the whitespace around it. */
function headingText(t: string): string {
  let end = t.trimEnd().length;
  while (end > 0 && t[end - 1] === "#") end--;
  return t.slice(0, end).trimEnd();
}

/** The blocks of markdown `md`, as far as the subset goes; the rest is paragraphs of text. */
export function parseRationale(md: string): Block[] {
  const lines = md.replace(/\r\n?/g, "\n").split("\n");
  const out: Block[] = [];
  let para: string[] = [];
  const flush = () => {
    if (para.length > 0) out.push({ kind: "paragraph", children: parseInline(para.join("\n")) });
    para = [];
  };
  const bullet = /^\s{0,3}([-*+])\s+(.*)$/;
  const numbered = /^\s{0,3}(\d{1,9})[.)]\s+(.*)$/;
  let i = 0;
  while (i < lines.length) {
    const line = lines[i] as string;
    const fence = /^\s{0,3}(```+|~~~+)/.exec(line);
    if (fence !== null) {
      flush();
      const mark = fence[1] as string;
      const body: string[] = [];
      i++;
      while (i < lines.length && !(lines[i] as string).trimStart().startsWith(mark)) {
        body.push(lines[i] as string);
        i++;
      }
      i++;
      out.push({ kind: "code", text: body.join("\n") });
      continue;
    }
    const heading = /^\s{0,3}(#{1,6})\s+([\s\S]*)$/.exec(line);
    if (heading !== null) {
      flush();
      out.push({
        kind: "heading",
        level: (heading[1] as string).length,
        children: parseInline(headingText(heading[2] as string)),
      });
      i++;
      continue;
    }
    if (line.trim() === "") {
      flush();
      i++;
      continue;
    }
    if (/^\s{0,3}>/.test(line)) {
      flush();
      const body: string[] = [];
      while (i < lines.length && /^\s{0,3}>/.test(lines[i] as string)) {
        body.push((lines[i] as string).replace(/^\s{0,3}>\s?/, ""));
        i++;
      }
      out.push({ kind: "quote", children: parseInline(body.join("\n")) });
      continue;
    }
    const first = bullet.exec(line) ?? numbered.exec(line);
    if (first !== null) {
      flush();
      const ordered = numbered.test(line) && !bullet.test(line);
      const pattern = ordered ? numbered : bullet;
      const items: string[] = [];
      while (i < lines.length) {
        const l = lines[i] as string;
        const m = pattern.exec(l);
        if (m !== null) items.push(m[2] as string);
        else if (l.trim() !== "" && /^\s+/.test(l) && items.length > 0)
          items[items.length - 1] += `\n${l.trim()}`;
        else break;
        i++;
      }
      out.push({ kind: "list", ordered, items: items.map((t) => parseInline(t)) });
      continue;
    }
    para.push(line);
    i++;
  }
  flush();
  return out;
}