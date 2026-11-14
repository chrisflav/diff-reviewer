import type { ReactNode } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { MemoryRouter } from "react-router-dom";
import { describe, expect, it } from "vitest";
import type { RubricView } from "../api";
import { EditLinks, ShownRubric } from "./Rubric";

const sha = "0123456789abcdef0123456789abcdef01234567";
const gh = "https://github.com/chrisflav/review-rubrics";

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
  defaultRubric: "No `sorry`. <script>alert('a rubric is text')</script>",
  prTypes: [
    {
      name: "feature",
      description: "Adds definitions.",
      rubric: "Check names.",
      categories: [{ name: "naming", description: "Against the convention." }],
      fanout: true,
      colour: "green",
    },
  ],
  fanout: false,
  styleNotes: "One sentence a comment.",
  files: [
    {
      path: "acme/widgets/rubric.md",
      url: `${gh}/blob/${sha}/acme/widgets/rubric.md`,
      editUrl: `${gh}/edit/main/acme/widgets/rubric.md`,
    },
    {
      path: "acme/widgets/style.md",
      url: "javascript:alert(1)",
      editUrl: `${gh}/edit/main/acme/widgets/style.md`,
    },
  ],
  treeUrl: `${gh}/tree/main/acme/widgets`,
  legacyVersion: null,
  derivedFrom: [],
  derivedFromPulls: [],
  reviewers: ["kim"],
};

const render = (node: ReactNode) =>
  renderToStaticMarkup(<MemoryRouter>{node}</MemoryRouter>);

describe("ShownRubric", () => {
  const html = render(<ShownRubric v={view} />);

  it("shows the default rubric, the types and the style notes, as text", () => {
    expect(html).toContain("&lt;script&gt;alert(&#x27;a rubric is text&#x27;)&lt;/script&gt;");
    expect(html).not.toContain("<script>");
    expect(html).toContain("Adds definitions.");
    expect(html).toContain("Against the convention.");
    expect(html).toContain("One sentence a comment.");
  });

  it("shows fan-out, of every review and of a type", () => {
    expect(html).toMatch(/Fan-out of every review: <strong>off<\/strong>/);
    expect(html).toContain('<span class="tag">fan-out</span>');
  });

  it("shows front matter this build does not know, of the rubric and of a type", () => {
    expect(html).toContain("Other fields");
    expect(html).toContain("reviewers");
    expect(html).toContain("[&quot;kim&quot;]");
    expect(html).toContain("colour");
  });

  it("says when there is no rubric at the commit", () => {
    expect(render(<ShownRubric v={{ ...view, exists: false }} />)).toContain("No rubric at this");
  });
});

describe("EditLinks", () => {
  const html = render(<EditLinks v={view} repoUrl={gh} />);

  it("links each file at the commit and in GitHub's editor, and the directory", () => {
    expect(html).toContain(`href="${gh}/blob/${sha}/acme/widgets/rubric.md"`);
    expect(html).toContain(`href="${gh}/edit/main/acme/widgets/rubric.md"`);
    expect(html).toContain(`href="${gh}/edit/main/acme/widgets/style.md"`);
    expect(html).toContain(`href="${gh}/tree/main/acme/widgets"`);
    // There is nothing to save here: the rubric is changed on GitHub.
    expect(html).not.toMatch(/<button|<textarea/);
  });

  it("never links an address that is not GitHub's", () => {
    expect(html).not.toContain("javascript:");
  });

  it("offers to create the rubric when the directory does not exist", () => {
    const none = render(<EditLinks v={{ ...view, exists: false, files: [] }} repoUrl={gh} />);
    expect(none).toContain("has no directory");
    expect(none).toContain(`href="${gh}/new/main?filename=acme%2Fwidgets%2Frubric.md"`);
  });
});