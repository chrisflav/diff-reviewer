import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { RubricProposal, RubricProposalDiff } from "../api";
import { Decide } from "../pages/Proposals";
import { ProposalDiffView, ProposedDocumentView, Rationale, StyleNotesDiff } from "./Proposal";

const diff: RubricProposalDiff = {
  defaultRubric: { before: "No sorry.", after: "No sorry.\nNo admit." },
  typesAdded: [
    {
      name: "docs",
      description: "Only documentation.",
      rubric: "<img src=x onerror=alert(1)>",
      categories: [{ name: "typo", description: "A typo." }],
    },
  ],
  typesRemoved: ["refactor"],
  typesChanged: [
    {
      name: "feature",
      description: null,
      rubric: { before: "Check names.", after: "Check names and docstrings." },
      categoriesAdded: [{ name: "docs", description: "Missing documentation." }],
      categoriesRemoved: ["style"],
      categoriesChanged: [{ name: "naming", before: "Names.", after: "Against the convention." }],
    },
  ],
  styleNotes: { before: "", after: "Be brief." },
};

describe("ProposalDiffView", () => {
  const html = renderToStaticMarkup(<ProposalDiffView diff={diff} />);

  it("shows the default rubric as a line diff", () => {
    expect(html).toContain("Default rubric");
    expect(html).toMatch(/class="tl same">.*No sorry\./);
    expect(html).toMatch(/class="tl add">.*No admit\./);
  });

  it("lists the types added, removed and changed", () => {
    expect(html).toContain("Types added (1)");
    expect(html).toContain("Only documentation.");
    expect(html).toContain("Types removed (1)");
    expect(html).toContain("refactor");
    expect(html).toContain("Types changed (1)");
  });

  it("shows a changed type's rubric, and its categories added, removed and changed", () => {
    expect(html).toContain("Rubric of feature");
    expect(html).toMatch(/class="tl del">.*Check names\./);
    expect(html).toMatch(/class="tl add">.*Check names and docstrings\./);
    expect(html).toContain("Categories added");
    expect(html).toContain("Missing documentation.");
    expect(html).toContain("Categories removed");
    expect(html).toContain("style");
    expect(html).toContain("Category naming of feature");
    expect(html).toContain("Against the convention.");
    // A text that did not change says nothing.
    expect(html).not.toContain("Description of feature");
  });

  it("shows what it is given as text", () => {
    expect(html).not.toContain("<img");
    expect(html).toContain("&lt;img src=x onerror=alert(1)&gt;");
  });

  it("says when the rubric is unchanged", () => {
    const none = renderToStaticMarkup(
      <ProposalDiffView
        diff={{
          defaultRubric: null,
          typesAdded: [],
          typesRemoved: [],
          typesChanged: [],
          styleNotes: null,
        }}
      />,
    );
    expect(none).toContain("changes nothing of the rubric");
  });

  it("shows the style notes as a diff, or that they are the same", () => {
    expect(renderToStaticMarkup(<StyleNotesDiff change={diff.styleNotes} />)).toMatch(
      /class="tl add">.*Be brief\./,
    );
    expect(renderToStaticMarkup(<StyleNotesDiff change={null} />)).toContain("say what the notes");
  });
});

describe("ProposedDocumentView", () => {
  it("shows the whole document, as text, when there is no diff", () => {
    const html = renderToStaticMarkup(
      <ProposedDocumentView doc={{ defaultRubric: "No sorry.", prTypes: diff.typesAdded }} />,
    );
    expect(html).toContain("No sorry.");
    expect(html).toContain("Types (1)");
    expect(html).toContain("&lt;img src=x onerror=alert(1)&gt;");
    expect(html).not.toContain("diff-added");
  });
});

describe("Rationale", () => {
  const hostile = [
    "# Why <script>alert('h')</script>",
    "",
    "<script>alert(1)</script>",
    "",
    'An image: <img src=x onerror="alert(2)">',
    "",
    "A [link](javascript:alert(3)) and [another](https://example.com).",
    "",
    "- **bold <b>not bold</b>**",
    "- `<code>`",
    "",
    "```html",
    "<iframe src=javascript:alert(4)></iframe>",
    "```",
  ].join("\n");
  const html = renderToStaticMarkup(<Rationale text={hostile} />);

  it("makes no element of what the agent wrote", () => {
    expect(html).not.toMatch(/<script/i);
    expect(html).not.toMatch(/<img/i);
    expect(html).not.toMatch(/<iframe/i);
    expect(html).not.toMatch(/<b>/);
    // No tag has an event handler: what reads like one is inside the text.
    expect(html).not.toMatch(/<[^>]*\son\w+=/i);
  });

  it("makes no link, of javascript: or anything else", () => {
    expect(html).not.toMatch(/<a\b/);
    expect(html).not.toMatch(/href=/);
    expect(html).toContain("link");
    expect(html).toContain("(javascript:alert(3))");
    expect(html).toContain("(https://example.com)");
  });

  it("shows the markup as escaped text", () => {
    expect(html).toContain("&lt;script&gt;alert(1)&lt;/script&gt;");
    expect(html).toContain("&lt;img src=x onerror=&quot;alert(2)&quot;&gt;");
    expect(html).toContain("&lt;iframe src=javascript:alert(4)&gt;&lt;/iframe&gt;");
  });

  it("keeps the subset it reads", () => {
    expect(html).toMatch(/<h4>Why /);
    expect(html).toContain("<strong>bold &lt;b&gt;not bold&lt;/b&gt;</strong>");
    expect(html).toContain("<code>&lt;code&gt;</code>");
    expect(html).toMatch(/<pre class="data">/);
  });
});

describe("Decide", () => {
  const p: RubricProposal = {
    id: "p1",
    owner: "o",
    name: "n",
    jobId: "j1",
    status: "pending",
    baseVersion: 2,
    currentVersion: 2,
    rebaseNeeded: false,
    rationale: "",
    proposesStyleNotes: true,
    createdAt: "t",
    decidedAt: null,
    acceptedVersion: null,
    document: { defaultRubric: "No sorry.", prTypes: [] },
  };
  const render = (q: RubricProposal, applyNotes = false) =>
    renderToStaticMarkup(
      <Decide
        p={q}
        applyNotes={applyNotes}
        setApplyNotes={() => {}}
        busy={false}
        onAccept={() => {}}
        onReject={() => {}}
      />,
    );

  it("offers the style notes unticked, when the proposal has some", () => {
    const html = render(p);
    expect(html).toContain("Also apply the style notes");
    expect(html).toMatch(/<input type="checkbox" name="apply-style-notes"\/>/);
    expect(html).toContain("Accept as rubric version 3");
    expect(html).not.toContain("with the style notes");
  });

  it("says so on the button once ticked", () => {
    const html = render(p, true);
    expect(html).toMatch(/name="apply-style-notes" checked=""/);
    expect(html).toContain("with the style notes");
  });

  it("does not offer notes a proposal does not have", () => {
    expect(render({ ...p, proposesStyleNotes: false })).not.toContain("style notes");
  });

  it("does not offer to accept what cannot be shown", () => {
    const unseen = render({ ...p, document: null, diff: null, diffError: "unreadable" });
    expect(unseen).toMatch(/<button type="button" disabled="">Accept/);
    expect(unseen).toContain("cannot be accepted from this page");
    // The document alone is enough: the page shows it in full.
    expect(render({ ...p, diff: null, diffError: "unreadable" })).not.toContain("disabled");
  });
});