import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { parseDiff } from "../diff";
import { placeComments, toLocal } from "../review";
import type { CommentActions } from "./Comments";
import { DiffView, FOLD_LINES, type Selection } from "./DiffView";

const actions: CommentActions = {
  add: () => {},
  update: () => {},
  remove: () => {},
  cancelSelection: () => {},
};

const diff = `diff --git a/a.ts b/a.ts
--- a/a.ts
+++ b/a.ts
@@ -1,2 +1,2 @@
 const x = 1;
-<b>old</b>
+<img src=x onerror=alert(1)>
`;

function render(
  text: string,
  bodies: string[],
  editable: boolean,
  selection: Selection | null = null,
  canAdd: boolean = editable,
) {
  const files = parseDiff(text);
  const review = toLocal({
    decision: "comment",
    body: "",
    comments: bodies.map((body) => ({ file: "a.ts", start_line: 1, end_line: 2, body })),
  });
  return renderToStaticMarkup(
    <DiffView
      files={files}
      placement={placeComments(files, review.comments)}
      editable={editable}
      canAdd={canAdd}
      selection={selection}
      onSelect={() => {}}
      onRangeChange={() => {}}
      actions={actions}
      suggestionSeed={() => null}
    />,
  );
}

describe("DiffView", () => {
  it("shows the diff's and the review's text as text", () => {
    const html = render(diff, ["<script>alert(1)</script>"], false);
    expect(html).not.toContain("<script>");
    expect(html).not.toContain("<img");
    expect(html).toContain("&lt;script&gt;alert(1)&lt;/script&gt;");
    expect(html).toContain("&lt;img src=x onerror=alert(1)&gt;");
  });

  it("puts a comment after the line it ends on", () => {
    const html = render(diff, ["the comment"], false);
    expect(html.indexOf("the comment")).toBeGreaterThan(html.indexOf("onerror"));
    expect(html).toContain("lines 1–2");
  });

  it("offers line numbers as buttons only when the review can be edited", () => {
    expect(render(diff, [], false)).not.toContain('class="lnum"');
    const html = render(diff, [], true);
    expect(html).toContain('aria-label="Comment on line 2 of a.ts (added)"');
    // One tab stop per file.
    expect(html.match(/tabindex="0"/g)).toHaveLength(1);
  });

  it("opens the comment form under the last picked line", () => {
    const html = render(diff, [], true, { file: "a.ts", start: 1, end: 2, anchor: 1 });
    expect(html).toContain("Add comment");
    expect(html.indexOf("Add comment")).toBeGreaterThan(html.indexOf("onerror"));
  });

  it("folds a large file", () => {
    const n = FOLD_LINES + 1;
    const big = `diff --git a/a.ts b/a.ts
--- a/a.ts
+++ b/a.ts
@@ -0,0 +1,${n} @@
${Array.from({ length: n }, (_, i) => `+line ${i}`).join("\n")}
`;
    const html = render(big, [], false);
    expect(html).toContain("a.ts");
    expect(html).not.toContain("line 7");
    expect(html).not.toMatch(/<details[^>]*open/);
  });

  it("shows what it could not read, open, and sizes the number columns", () => {
    const html = render(
      diff.replace("@@ -1,2 +1,2 @@", "@@ -99999,2 +99999,2 @@") + "@@ -x @@\n",
      [],
      false,
    );
    expect(html).toContain("Unreadable hunk header: @@ -x @@");
    expect(html).toContain("digits-6");
  });

  it("offers no line to comment on past the cap, and keeps the comments editable", () => {
    const html = render(diff, ["kept"], true, null, false);
    expect(html).not.toContain('class="lnum"');
    expect(html).toContain("Edit");
  });
});