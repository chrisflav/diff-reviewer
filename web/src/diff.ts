/**
 * A parser for unified diffs as `git diff` and GitHub's `.diff` write them.
 *
 * Hand-rolled because the subset a pull request diff uses is small and its traps are few and
 * known: a hunk is read by its line counts, not by what its lines look like, so a removed line
 * reading `-- x` (which the diff writes as `--- x`) or an added `diff --git` is never taken for
 * a header.
 */

export type LineKind = "context" | "add" | "del";

export interface DiffLine {
  kind: LineKind;
  /** The line number on the old side, for context and deleted lines. */
  oldLine: number | null;
  /** The line number on the new (RIGHT) side, for context and added lines. */
  newLine: number | null;
  text: string;
  /** The line is followed by `\ No newline at end of file`. */
  noNewline: boolean;
}

export interface Hunk {
  header: string;
  oldStart: number;
  oldCount: number;
  newStart: number;
  newCount: number;
  lines: DiffLine[];
}

export type FileChange = "modified" | "added" | "deleted" | "renamed" | "copied";

export interface DiffFile {
  /** The path before the change; `null` for an added file. */
  oldPath: string | null;
  /** The path after the change; `null` for a deleted file. Review comments name this one. */
  newPath: string | null;
  change: FileChange;
  binary: boolean;
  hunks: Hunk[];
  /** Extended header lines (`index …`, `new file mode …`, `similarity index …`), as written. */
  meta: string[];
}

/** The path a file is known by in the view: its new path, or its old one once deleted. */
export function displayPath(f: DiffFile): string {
  return f.newPath ?? f.oldPath ?? "(unnamed)";
}

/** Lines of a file's hunks; what "large" is measured in. */
export function lineCount(f: DiffFile): number {
  return f.hunks.reduce((n, h) => n + h.lines.length, 0);
}

const hunkHeader = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)$/;

export function parseDiff(text: string): DiffFile[] {
  const lines = text.split("\n");
  if (lines.length > 0 && lines[lines.length - 1] === "") lines.pop();
  const files: DiffFile[] = [];
  let file: DiffFile | null = null;
  let i = 0;

  const startFile = (): DiffFile => {
    const f: DiffFile = {
      oldPath: null,
      newPath: null,
      change: "modified",
      binary: false,
      hunks: [],
      meta: [],
    };
    files.push(f);
    return f;
  };

  while (i < lines.length) {
    const line = lines[i] ?? "";

    if (line.startsWith("diff --git ")) {
      file = startFile();
      const paths = gitHeaderPaths(line.slice("diff --git ".length));
      if (paths !== null) {
        file.oldPath = paths[0];
        file.newPath = paths[1];
      }
      i++;
      continue;
    }

    // A plain (non-git) unified diff starts a file at its `---` line.
    if (line.startsWith("--- ") && (lines[i + 1] ?? "").startsWith("+++ ")) {
      if (file === null || file.hunks.length > 0 || sawMarkers(file)) file = startFile();
      file.oldPath = markerPath(line.slice(4), "a/");
      file.newPath = markerPath((lines[i + 1] ?? "").slice(4), "b/");
      file.meta.push(line, lines[i + 1] ?? "");
      if (file.oldPath === null) file.change = "added";
      else if (file.newPath === null) file.change = "deleted";
      i += 2;
      continue;
    }

    const m = hunkHeader.exec(line);
    if (m !== null && file !== null) {
      const hunk: Hunk = {
        header: line,
        oldStart: Number(m[1]),
        oldCount: m[2] === undefined ? 1 : Number(m[2]),
        newStart: Number(m[3]),
        newCount: m[4] === undefined ? 1 : Number(m[4]),
        lines: [],
      };
      file.hunks.push(hunk);
      i = readHunk(lines, i + 1, hunk);
      continue;
    }

    if (file !== null) {
      file.meta.push(line);
      if (line.startsWith("new file mode")) {
        file.change = "added";
        file.oldPath = null;
      } else if (line.startsWith("deleted file mode")) {
        file.change = "deleted";
        file.newPath = null;
      } else if (line.startsWith("rename from ")) {
        file.change = "renamed";
        file.oldPath = unquote(line.slice("rename from ".length));
      } else if (line.startsWith("rename to ")) {
        file.change = "renamed";
        file.newPath = unquote(line.slice("rename to ".length));
      } else if (line.startsWith("copy from ")) {
        file.change = "copied";
        file.oldPath = unquote(line.slice("copy from ".length));
      } else if (line.startsWith("copy to ")) {
        file.change = "copied";
        file.newPath = unquote(line.slice("copy to ".length));
      } else if (line.startsWith("Binary files ") || line === "GIT binary patch") {
        file.binary = true;
      }
    }
    i++;
  }
  return files;
}

function sawMarkers(f: DiffFile): boolean {
  return f.meta.some((l) => l.startsWith("--- "));
}

/** Read a hunk's lines from `start`, by its counts; answers the index after the hunk. */
function readHunk(lines: string[], start: number, hunk: Hunk): number {
  let oldLeft = hunk.oldCount;
  let newLeft = hunk.newCount;
  let oldLine = hunk.oldStart;
  let newLine = hunk.newStart;
  let i = start;
  while (i < lines.length && (oldLeft > 0 || newLeft > 0)) {
    const line = lines[i] ?? "";
    const tag = line.charAt(0);
    if (tag === "+" && newLeft > 0) {
      hunk.lines.push({
        kind: "add",
        oldLine: null,
        newLine,
        text: line.slice(1),
        noNewline: false,
      });
      newLine++;
      newLeft--;
    } else if (tag === "-" && oldLeft > 0) {
      hunk.lines.push({
        kind: "del",
        oldLine,
        newLine: null,
        text: line.slice(1),
        noNewline: false,
      });
      oldLine++;
      oldLeft--;
    } else if ((tag === " " || line === "") && oldLeft > 0 && newLeft > 0) {
      // Some tools strip the space of an empty context line; it is still one.
      hunk.lines.push({ kind: "context", oldLine, newLine, text: line.slice(1), noNewline: false });
      oldLine++;
      newLine++;
      oldLeft--;
      newLeft--;
    } else if (tag === "\\") {
      markNoNewline(hunk);
    } else {
      // The counts promised more than the text holds: stop here rather than eat the next file.
      break;
    }
    i++;
  }
  // The marker may follow the hunk's last line.
  if ((lines[i] ?? "").startsWith("\\")) {
    markNoNewline(hunk);
    i++;
  }
  return i;
}

function markNoNewline(hunk: Hunk) {
  const last = hunk.lines[hunk.lines.length - 1];
  if (last !== undefined) last.noNewline = true;
}

/** The `---`/`+++` path, without its `a/` or `b/` prefix; `null` for `/dev/null`. */
function markerPath(raw: string, prefix: string): string | null {
  // A tab may separate a timestamp in non-git diffs.
  const p = unquote(raw.split("\t")[0] ?? "");
  if (p === "/dev/null") return null;
  return p.startsWith(prefix) ? p.slice(prefix.length) : p;
}

/**
 * The two paths of `a/X b/Y`. Paths with spaces are ambiguous here; the common case, an
 * unrenamed file, is the one whose halves agree. A rename's `rename from/to` lines and the
 * `---`/`+++` lines, read later, correct whatever this guesses.
 */
function gitHeaderPaths(rest: string): [string, string] | null {
  if (rest.startsWith('"')) {
    const end = quotedEnd(rest);
    const a = unquote(rest.slice(0, end));
    const b = unquote(rest.slice(end + 1));
    return [strip(a, "a/"), strip(b, "b/")];
  }
  const n = (rest.length - 5) / 2;
  if (Number.isInteger(n) && rest.startsWith("a/") && rest.slice(2 + n, 5 + n) === " b/") {
    const a = rest.slice(2, 2 + n);
    if (a === rest.slice(5 + n)) return [a, a];
  }
  const at = rest.lastIndexOf(" b/");
  if (at < 0) return null;
  return [strip(rest.slice(0, at), "a/"), unquote(rest.slice(at + 3))];
}

function strip(p: string, prefix: string): string {
  return p.startsWith(prefix) ? p.slice(prefix.length) : p;
}

/** The index just past the closing quote of the C-quoted string at the start of `s`. */
function quotedEnd(s: string): number {
  for (let i = 1; i < s.length; i++) {
    if (s[i] === "\\") i++;
    else if (s[i] === '"') return i + 1;
  }
  return s.length;
}

const escapes: Record<string, number> = { a: 7, b: 8, t: 9, n: 10, v: 11, f: 12, r: 13 };

/**
 * Git's C-style quoting of a path with unusual bytes: `"caf\303\251.txt"`. Octal escapes are
 * bytes of UTF-8, so the bytes are collected and decoded together.
 */
export function unquote(s: string): string {
  if (!(s.length >= 2 && s.startsWith('"') && s.endsWith('"'))) return s;
  const bytes: number[] = [];
  const enc = new TextEncoder();
  for (let i = 1; i < s.length - 1; i++) {
    const c = s.charAt(i);
    if (c !== "\\") {
      // Whole code points, so that a character outside the BMP is not split in two.
      const cp = String.fromCodePoint(s.codePointAt(i) ?? 0);
      bytes.push(...enc.encode(cp));
      i += cp.length - 1;
      continue;
    }
    const d = s.charAt(++i);
    if (/[0-7]/.test(d)) {
      const oct = s.slice(i, i + 3);
      bytes.push(parseInt(oct, 8));
      i += oct.length - 1;
    } else {
      bytes.push(escapes[d] ?? d.charCodeAt(0));
    }
  }
  return new TextDecoder().decode(new Uint8Array(bytes));
}