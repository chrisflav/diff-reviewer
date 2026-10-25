import type { ReactNode } from "react";
import type { Category, PrType, RubricProposalDiff, TextChange } from "../api";
import { parseRationale, rubricUnchanged, type Block, type Inline } from "../proposals";
import { TextDiff } from "./History";

/**
 * A rationale: markdown an agent wrote, shown through the small subset `parseRationale` reads.
 * Every piece is a text node, which React escapes: no HTML of it is ever made, and a link is its
 * text with its address beside it, never something to follow.
 */
export function Rationale({ text }: { text: string }) {
  const blocks = parseRationale(text);
  if (blocks.length === 0) return <p className="mute">(empty)</p>;
  return <div className="rationale">{blocks.map((b, i) => block(b, i))}</div>;
}

function block(b: Block, key: number): ReactNode {
  switch (b.kind) {
    case "heading": {
      // Under the page's own headings: a rationale's `#` is the page's fourth level.
      const level = Math.min(6, b.level + 3);
      const H = `h${level}` as "h4" | "h5" | "h6";
      return <H key={key}>{inlines(b.children)}</H>;
    }
    case "paragraph":
      return (
        <p key={key} className="body">
          {inlines(b.children)}
        </p>
      );
    case "quote":
      return (
        <blockquote key={key} className="body">
          {inlines(b.children)}
        </blockquote>
      );
    case "code":
      return (
        <pre key={key} className="data">
          {b.text}
        </pre>
      );
    case "list": {
      const items = b.items.map((it, i) => (
        <li key={i} className="body">
          {inlines(it)}
        </li>
      ));
      return b.ordered ? <ol key={key}>{items}</ol> : <ul key={key}>{items}</ul>;
    }
  }
}

function inlines(xs: Inline[]): ReactNode[] {
  return xs.map((x, i) => {
    switch (x.kind) {
      case "text":
        return x.text;
      case "code":
        return <code key={i}>{x.text}</code>;
      case "strong":
        return <strong key={i}>{inlines(x.children)}</strong>;
      case "em":
        return <em key={i}>{inlines(x.children)}</em>;
      case "link":
        return (
          <span key={i} className="inert-link">
            {inlines(x.children)}
            {x.target !== "" && (
              <>
                {" "}
                <span className="mute data">({x.target})</span>
              </>
            )}
          </span>
        );
    }
  });
}

/** A text before and after, or a note that it did not change. */
function Change({ label, change, code }: { label: string; change: TextChange; code?: boolean }) {
  if (change === null) return null;
  return (
    <div className="change">
      <h5>{label}</h5>
      <TextDiff before={change.before} after={change.after} label={label} code={code ?? false} />
    </div>
  );
}

function Categories({ cs }: { cs: Category[] }) {
  if (cs.length === 0) return <p className="mute small-text">No categories: free text.</p>;
  return (
    <dl className="cats-shown">
      {cs.map((c, j) => (
        <div key={j}>
          <dt className="data">{c.name}</dt>
          <dd className="body">{c.description}</dd>
        </div>
      ))}
    </dl>
  );
}

function ShownType({ t, added }: { t: PrType; added: boolean }) {
  return (
    <article className={added ? "shown-type diff-added" : "shown-type"}>
      <h5 className="data">
        {added && <span className="sr-only">Added: </span>}
        {t.name}
      </h5>
      {t.description !== "" && <p className="body">{t.description}</p>}
      <div className="preview body">
        {t.rubric === "" ? <span className="mute">(no rubric of its own)</span> : t.rubric}
      </div>
      <Categories cs={t.categories ?? []} />
    </article>
  );
}

/**
 * What a proposal changes of the rubric it was written from, as the server worked it out: the
 * default rubric's text, the types added and removed, and each type changed — its description,
 * its rubric and its categories. All of it text.
 */
export function ProposalDiffView({ diff }: { diff: RubricProposalDiff }) {
  if (rubricUnchanged(diff))
    return <p className="mute">The proposal changes nothing of the rubric.</p>;
  return (
    <div className="proposal-diff">
      {diff.defaultRubric === null ? (
        <p className="mute small-text">The default rubric is unchanged.</p>
      ) : (
        <Change label="Default rubric" change={diff.defaultRubric} />
      )}
      {diff.typesAdded.length > 0 && (
        <section aria-labelledby="types-added-h">
          <h4 id="types-added-h">Types added ({diff.typesAdded.length})</h4>
          {diff.typesAdded.map((t, i) => (
            <ShownType key={i} t={t} added />
          ))}
        </section>
      )}
      {diff.typesRemoved.length > 0 && (
        <section aria-labelledby="types-removed-h">
          <h4 id="types-removed-h">Types removed ({diff.typesRemoved.length})</h4>
          <ul className="chips removed">
            {diff.typesRemoved.map((n, i) => (
              <li key={i} className="data">
                <span className="sr-only">Removed: </span>
                {n}
              </li>
            ))}
          </ul>
        </section>
      )}
      {diff.typesChanged.length > 0 && (
        <section aria-labelledby="types-changed-h">
          <h4 id="types-changed-h">Types changed ({diff.typesChanged.length})</h4>
          {diff.typesChanged.map((t, i) => (
            <article key={i} className="shown-type diff-changed">
              <h5 className="data">{t.name}</h5>
              <Change label={`Description of ${t.name}`} change={t.description} />
              <Change label={`Rubric of ${t.name}`} change={t.rubric} />
              {t.categoriesAdded.length > 0 && (
                <div className="change">
                  <h5>Categories added</h5>
                  <Categories cs={t.categoriesAdded} />
                </div>
              )}
              {t.categoriesRemoved.length > 0 && (
                <div className="change">
                  <h5>Categories removed</h5>
                  <ul className="chips removed">
                    {t.categoriesRemoved.map((n, j) => (
                      <li key={j} className="data">
                        <span className="sr-only">Removed: </span>
                        {n}
                      </li>
                    ))}
                  </ul>
                </div>
              )}
              {t.categoriesChanged.map((c, j) => (
                <Change
                  key={`c${j}`}
                  label={`Category ${c.name} of ${t.name}`}
                  change={{ before: c.before, after: c.after }}
                />
              ))}
            </article>
          ))}
        </section>
      )}
    </div>
  );
}

/**
 * A proposal's document in full, for when there is no diff to show: the default rubric and each
 * type, all of it text.
 */
export function ProposedDocumentView({
  doc,
}: {
  doc: { defaultRubric: string; prTypes: PrType[] };
}) {
  return (
    <div className="proposal-diff">
      <div className="change">
        <h5>Default rubric</h5>
        <div className="preview body">
          {doc.defaultRubric === "" ? <span className="mute">(none)</span> : doc.defaultRubric}
        </div>
      </div>
      <section aria-labelledby="types-shown-h">
        <h4 id="types-shown-h">Types ({doc.prTypes.length})</h4>
        {doc.prTypes.length === 0 && <p className="mute small-text">None.</p>}
        {doc.prTypes.map((t, i) => (
          <ShownType key={i} t={t} added={false} />
        ))}
      </section>
    </div>
  );
}

/** The style notes a proposal proposes, against those its agent was given. */
export function StyleNotesDiff({ change }: { change: TextChange }) {
  if (change === null)
    return (
      <p className="mute small-text">
        The proposal's style notes say what the notes its agent was given said.
      </p>
    );
  return <TextDiff before={change.before} after={change.after} label="Style notes" />;
}