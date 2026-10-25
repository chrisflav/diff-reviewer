import { describe, expect, it } from "vitest";
import { parseDiff, unquote } from "./diff";

const modified = `diff --git a/src/a.ts b/src/a.ts
index 1111111..2222222 100644
--- a/src/a.ts
+++ b/src/a.ts
@@ -1,4 +1,5 @@ export function f() {
 one
-two
+TWO
+three
 four

@@ -10,2 +11,2 @@
 ten
-eleven
+ELEVEN
`;

describe("parseDiff", () => {
  it("numbers both sides of each hunk", () => {
    const [f, ...rest] = parseDiff(modified);
    expect(rest).toHaveLength(0);
    expect(f?.oldPath).toBe("src/a.ts");
    expect(f?.newPath).toBe("src/a.ts");
    expect(f?.change).toBe("modified");
    expect(f?.hunks).toHaveLength(2);
    const lines = f?.hunks[0]?.lines.map((l) => [l.kind, l.oldLine, l.newLine, l.text]);
    expect(lines).toEqual([
      ["context", 1, 1, "one"],
      ["del", 2, null, "two"],
      ["add", null, 2, "TWO"],
      ["add", null, 3, "three"],
      ["context", 3, 4, "four"],
      // A blank context line whose space was stripped is still a line.
      ["context", 4, 5, ""],
    ]);
    expect(f?.hunks[1]?.lines.map((l) => l.newLine)).toEqual([11, null, 12]);
  });

  it("reads a hunk by its counts, not by what its lines look like", () => {
    const text = `diff --git a/x.md b/x.md
--- a/x.md
+++ b/x.md
@@ -1,2 +1,3 @@
--- a rule
+++ plus plus
+diff --git a/y b/y
 @@ not a hunk
diff --git a/z b/z
--- a/z
+++ b/z
@@ -1 +1 @@
-z
+Z
`;
    const files = parseDiff(text);
    expect(files.map((f) => f.newPath)).toEqual(["x.md", "z"]);
    expect(files[0]?.hunks[0]?.lines.map((l) => [l.kind, l.text])).toEqual([
      ["del", "-- a rule"],
      ["add", "++ plus plus"],
      ["add", "diff --git a/y b/y"],
      ["context", "@@ not a hunk"],
    ]);
    expect(files[1]?.hunks[0]?.lines.map((l) => [l.kind, l.oldLine, l.newLine])).toEqual([
      ["del", 1, null],
      ["add", null, 1],
    ]);
  });

  it("knows added, deleted, renamed and binary files", () => {
    const text = `diff --git a/new.txt b/new.txt
new file mode 100644
index 0000000..1111111
--- /dev/null
+++ b/new.txt
@@ -0,0 +1,2 @@
+a
+b
diff --git a/old.txt b/old.txt
deleted file mode 100644
index 1111111..0000000
--- a/old.txt
+++ /dev/null
@@ -1 +0,0 @@
-gone
diff --git a/from dir/f.txt b/to dir/f.txt
similarity index 100%
rename from from dir/f.txt
rename to to dir/f.txt
diff --git a/img.png b/img.png
index 1111111..2222222 100644
Binary files a/img.png and b/img.png differ
`;
    const files = parseDiff(text);
    expect(files.map((f) => [f.change, f.oldPath, f.newPath, f.binary, f.hunks.length])).toEqual([
      ["added", null, "new.txt", false, 1],
      ["deleted", "old.txt", null, false, 1],
      ["renamed", "from dir/f.txt", "to dir/f.txt", false, 0],
      ["modified", "img.png", "img.png", true, 0],
    ]);
    expect(files[0]?.hunks[0]?.lines.map((l) => l.newLine)).toEqual([1, 2]);
  });

  it("reads paths with spaces and quoted paths", () => {
    const text = `diff --git a/with space.txt b/with space.txt
--- a/with space.txt
+++ b/with space.txt
@@ -1 +1 @@
-a
+b
diff --git "a/caf\\303\\251.txt" "b/caf\\303\\251.txt"
--- "a/caf\\303\\251.txt"
+++ "b/caf\\303\\251.txt"
@@ -1 +1 @@
-a
+b
`;
    expect(parseDiff(text).map((f) => f.newPath)).toEqual(["with space.txt", "café.txt"]);
  });

  it("notes a missing newline at the end of a file", () => {
    const text = `diff --git a/f b/f
--- a/f
+++ b/f
@@ -1 +1 @@
-a
\\ No newline at end of file
+a
\\ No newline at end of file
`;
    const lines = parseDiff(text)[0]?.hunks[0]?.lines;
    expect(lines?.map((l) => [l.kind, l.noNewline])).toEqual([
      ["del", true],
      ["add", true],
    ]);
  });

  it("reads plain unified diffs without git headers", () => {
    const text = `--- a/one\t2024-01-01
+++ b/one\t2024-01-02
@@ -1 +1 @@
-1
+one
--- a/two
+++ b/two
@@ -1 +1,2 @@
 2
+two
`;
    const files = parseDiff(text);
    expect(files.map((f) => f.newPath)).toEqual(["one", "two"]);
    expect(files[1]?.hunks[0]?.lines.map((l) => l.newLine)).toEqual([1, 2]);
  });

  it("reads an empty diff as no files", () => {
    expect(parseDiff("")).toEqual([]);
  });
});

describe("parseDiff, odd text", () => {
  const one = (header: string) => `diff --git a/f b/f
--- a/f
+++ b/f
${header}
-a
+b
`;

  it("reads a hunk whose function context holds line separators or a lone CR", () => {
    for (const ctx of ["\u2028", "\u2029", "x\ry"]) {
      const f = parseDiff(one(`@@ -1 +1 @@ function f() {${ctx}`))[0];
      expect(f?.problems).toEqual([]);
      expect(f?.hunks[0]?.lines.map((l) => l.kind)).toEqual(["del", "add"]);
    }
  });

  it("strips the CR of a CRLF diff, and keeps a CR inside a line of an LF one", () => {
    const crlf = parseDiff(one("@@ -1 +1 @@").replace(/\n/g, "\r\n"))[0];
    expect(crlf?.newPath).toBe("f");
    expect(crlf?.hunks[0]?.lines.map((l) => l.text)).toEqual(["a", "b"]);
    const lf = parseDiff(one("@@ -1 +1 @@").replace("+b", "+b\r"))[0];
    expect(lf?.hunks[0]?.lines.map((l) => l.text)).toEqual(["a", "b\r"]);
  });

  it("says so when a hunk header cannot be read, instead of dropping the hunk", () => {
    const f = parseDiff(one("@@ -1,x +1 @@"))[0];
    expect(f?.problems).toEqual(["Unreadable hunk header: @@ -1,x +1 @@"]);
    expect(f?.meta).not.toContain("@@ -1,x +1 @@");
    const orphan = parseDiff("@@ -1 +1 @@\n-a\n+b\n")[0];
    expect(orphan?.problems).toHaveLength(1);
  });

  it("says so when a hunk holds fewer lines than its header promises", () => {
    const f = parseDiff(one("@@ -1,3 +1,3 @@"))[0];
    expect(f?.problems).toHaveLength(1);
    expect(f?.hunks[0]?.lines).toHaveLength(2);
  });
});

describe("unquote", () => {
  it("decodes C escapes as UTF-8 bytes and leaves plain strings alone", () => {
    expect(unquote('"a\\tb\\"c\\\\"')).toBe('a\tb"c\\');
    expect(unquote('"\\360\\237\\230\\200"')).toBe("😀");
    expect(unquote('"😀 ok"')).toBe("😀 ok");
    expect(unquote("plain")).toBe("plain");
  });
});