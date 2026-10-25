import {
  createContext,
  useContext,
  useEffect,
  useId,
  useRef,
  useState,
  type FormEvent,
} from "react";
import { severities, type InlineComment, type Severity } from "../api";
import { commentProblem, KEY, rangeLabel, type LocalComment } from "../review";
import { commentCategoryProblem } from "../rubric";
import { CategoryTag, SeverityBadge, severityHelp } from "./Severity";

/**
 * Where an open comment form says whether it holds text not yet in the review: typed text is
 * an unsaved edit too, and the page counts it as one.
 */
export const FormsContext = createContext<(id: string, dirty: boolean) => void>(() => {});

/**
 * The categories a comment of the job's review may be filed under, from the rubric version the
 * job was reviewed against (`categoriesFor`): empty is free text.
 */
export interface CategoryRules {
  allowed: string[];
  /** What each allowed category is for, as the rubric says. */
  descriptions: Map<string, string>;
  /** Why the rules are not known, when they are not: the form takes free text, the server checks. */
  note: string | null;
  /** The stored review's categories by comment id: a category left as stored is not checked. */
  stored: Map<string, string | undefined>;
}

export const CategoryContext = createContext<CategoryRules>({
  allowed: [],
  descriptions: new Map(),
  note: null,
  stored: new Map(),
});

/**
 * Where focus goes when `el`, a comment, leaves: the comment next to it, else the line it was
 * on, else the heading of its section. Never the page's body.
 */
function focusAfterLeaving(el: HTMLElement | null): HTMLElement | null {
  if (el === null) return null;
  for (const sib of [el.nextElementSibling, el.previousElementSibling])
    if (sib instanceof HTMLElement && sib.matches(".comment"))
      return sib.querySelector<HTMLElement>("button") ?? sib;
  const line = el
    .closest("tr.anchor")
    ?.previousElementSibling?.querySelector<HTMLElement>("button.lnum");
  return line ?? document.getElementById("outside-h") ?? document.getElementById("diff-h");
}

/** What a comment card may do to the review; stable across renders so files need not redraw. */
export interface CommentActions {
  update: (key: number, c: InlineComment) => void;
  remove: (key: number) => void;
  add: (c: InlineComment) => void;
  cancelSelection: () => void;
}

/**
 * One comment as the review has it. Its text came from an agent and is shown as text: React
 * escapes it, and nothing here renders markdown or HTML.
 */
export function CommentCard({
  comment,
  editable,
  actions,
  split = false,
  showFile = false,
  suggestionSeed,
}: {
  comment: LocalComment;
  editable: boolean;
  actions: CommentActions;
  /** The range starts outside the hunk it ends in. */
  split?: boolean;
  /** Name the file too, and let it be edited: for comments the diff does not place. */
  showFile?: boolean;
  /** The text of the commented lines, for a suggestion to start from. */
  suggestionSeed?: (file: string, start: number, end: number) => string | null;
}) {
  const [editing, setEditing] = useState(false);
  const card = useRef<HTMLElement>(null);
  const edit = useRef<HTMLButtonElement>(null);
  // Set when the form closes, so that focus returns to the Edit button it was opened from.
  const refocus = useRef(false);
  useEffect(() => {
    if (editing || !refocus.current) return;
    refocus.current = false;
    edit.current?.focus();
  }, [editing]);

  const close = () => {
    refocus.current = true;
    setEditing(false);
  };

  if (editing)
    return (
      <div className="comment">
        <CommentForm
          initial={comment}
          showFile={showFile}
          submitLabel="Apply"
          onSubmit={(c) => {
            actions.update(comment[KEY], c);
            close();
          }}
          onCancel={close}
          {...(suggestionSeed === undefined ? {} : { suggestionSeed })}
        />
      </div>
    );

  return (
    <article
      ref={card}
      id={`comment-${comment[KEY]}`}
      tabIndex={-1}
      className="comment"
      aria-label={`Comment on ${comment.file} ${rangeLabel(comment)}`}
    >
      <header>
        <span className="where data">
          {showFile && `${comment.file}, `}
          {rangeLabel(comment)}
        </span>
        <span className="labels">
          <SeverityBadge severity={comment.severity} />
          <CategoryTag category={comment.category} />
        </span>
        {editable && (
          <span className="tools">
            <button
              ref={edit}
              type="button"
              className="ghost small"
              onClick={() => setEditing(true)}
            >
              Edit
            </button>
            <button
              type="button"
              className="ghost small danger"
              onClick={() => {
                const next = focusAfterLeaving(card.current);
                actions.remove(comment[KEY]);
                requestAnimationFrame(() => next?.focus());
              }}
              aria-label={`Delete the comment on ${comment.file} ${rangeLabel(comment)}`}
            >
              Delete
            </button>
          </span>
        )}
      </header>
      {split && (
        <p className="warn small-text">
          This range starts outside the hunk it ends in; GitHub refuses such a comment. Narrow it to
          lines of one hunk.
        </p>
      )}
      {comment.body !== "" && <p className="body">{comment.body}</p>}
      {comment.suggestion !== undefined && (
        <figure className="suggestion">
          <figcaption className="mute small-text">Suggested change</figcaption>
          <pre>{comment.suggestion}</pre>
        </figure>
      )}
    </article>
  );
}

/** The fields of a comment, checked as the server checks them before they reach the review. */
export function CommentForm({
  initial,
  showFile,
  submitLabel,
  onSubmit,
  onCancel,
  onRangeChange,
  suggestionSeed,
}: {
  initial: InlineComment;
  showFile: boolean;
  submitLabel: string;
  onSubmit: (c: InlineComment) => void;
  onCancel: () => void;
  /** The lines were changed in the form; the view follows, so the selection stays honest. */
  onRangeChange?: (start: number, end: number) => void;
  suggestionSeed?: (file: string, start: number, end: number) => string | null;
}) {
  const id = useId();
  const [file, setFile] = useState(initial.file);
  const [start, setStart] = useState(String(initial.start_line));
  const [end, setEnd] = useState(String(initial.end_line));
  const [body, setBody] = useState(initial.body);
  const [suggesting, setSuggesting] = useState(initial.suggestion !== undefined);
  const [suggestion, setSuggestion] = useState(initial.suggestion ?? "");
  const [category, setCategory] = useState(initial.category ?? "");
  const [severity, setSeverity] = useState<Severity | "">(initial.severity ?? "");
  const [problem, setProblem] = useState<string | null>(null);
  const rules = useContext(CategoryContext);
  const picked = rules.allowed.length > 0;

  const report = useContext(FormsContext);
  const dirty =
    file.trim() !== initial.file ||
    start !== String(initial.start_line) ||
    end !== String(initial.end_line) ||
    body !== initial.body ||
    suggesting !== (initial.suggestion !== undefined) ||
    (suggesting && suggestion !== (initial.suggestion ?? "")) ||
    category !== (initial.category ?? "") ||
    severity !== (initial.severity ?? "");
  useEffect(() => report(id, dirty), [report, id, dirty]);
  useEffect(() => () => report(id, false), [report, id]);

  // The form's range follows a shift-click in the diff while it is open.
  const [seen, setSeen] = useState([initial.start_line, initial.end_line]);
  if (seen[0] !== initial.start_line || seen[1] !== initial.end_line) {
    setSeen([initial.start_line, initial.end_line]);
    setStart(String(initial.start_line));
    setEnd(String(initial.end_line));
  }

  const build = (): InlineComment => {
    const c: InlineComment = {
      file: file.trim(),
      start_line: Number(start),
      end_line: Number(end),
      body,
    };
    if (suggesting) c.suggestion = suggestion;
    // Free text the person typed is trimmed; a rubric's category, or one left as it was, is taken
    // as it is spelled.
    const cat = picked || category === (initial.category ?? "") ? category : category.trim();
    if (cat !== "") c.category = cat;
    if (severity !== "") c.severity = severity;
    return c;
  };

  const submit = (e: FormEvent) => {
    e.preventDefault();
    const c = build();
    const withId = initial.id === undefined ? c : { ...c, id: initial.id };
    const p = commentProblem(c) ?? commentCategoryProblem(withId, rules.allowed, rules.stored);
    if (p !== null) {
      setProblem(p);
      return;
    }
    onSubmit(c);
  };

  const rangeChanged = (s: string, e: string) => {
    const a = Number(s);
    const b = Number(e);
    if (
      onRangeChange !== undefined &&
      Number.isInteger(a) &&
      Number.isInteger(b) &&
      a >= 1 &&
      b >= a
    )
      onRangeChange(a, b);
  };

  return (
    <form
      className="comment-form"
      onSubmit={submit}
      onKeyDown={(e) => {
        if (e.key === "Escape") {
          e.preventDefault();
          onCancel();
        }
      }}
    >
      <div className="range-fields">
        {showFile && (
          <label className="grow">
            File
            <input className="data" value={file} onChange={(e) => setFile(e.target.value)} />
          </label>
        )}
        <label>
          From line
          <input
            className="data"
            inputMode="numeric"
            size={6}
            value={start}
            onChange={(e) => {
              setStart(e.target.value);
              rangeChanged(e.target.value, end);
            }}
          />
        </label>
        <label>
          to line
          <input
            className="data"
            inputMode="numeric"
            size={6}
            value={end}
            onChange={(e) => {
              setEnd(e.target.value);
              rangeChanged(start, e.target.value);
            }}
          />
        </label>
      </div>
      <div className="range-fields">
        <label>
          Severity
          <select value={severity} onChange={(e) => setSeverity(e.target.value as Severity | "")}>
            <option value="">(none)</option>
            {severities.map((s) => (
              <option key={s} value={s}>
                {s} — {severityHelp[s]}
              </option>
            ))}
          </select>
        </label>
        {picked ? (
          <label className="grow">
            Category
            <select
              value={category}
              onChange={(e) => setCategory(e.target.value)}
              aria-describedby={`${id}-cat`}
            >
              <option value="">(none)</option>
              {rules.allowed.map((c) => (
                <option key={c} value={c}>
                  {c}
                </option>
              ))}
              {initial.category !== undefined && !rules.allowed.includes(initial.category) && (
                <option value={initial.category}>{initial.category} (not in the rubric)</option>
              )}
            </select>
          </label>
        ) : (
          <label className="grow">
            Category
            <input
              value={category}
              placeholder="free text"
              aria-describedby={`${id}-cat`}
              onChange={(e) => setCategory(e.target.value)}
            />
          </label>
        )}
      </div>
      <p id={`${id}-cat`} className="mute small-text">
        {rules.note !== null
          ? rules.note
          : picked
            ? rules.descriptions.get(category) ||
              "The categories of the rubric the review was written to."
            : "The rubric names no categories for this review, so any category is free text."}
      </p>
      <label htmlFor={`${id}-body`} className="sr-only">
        Comment
      </label>
      <textarea
        id={`${id}-body`}
        rows={4}
        autoFocus
        placeholder="Comment"
        value={body}
        onChange={(e) => setBody(e.target.value)}
      />
      <label className="check">
        <input
          type="checkbox"
          checked={suggesting}
          onChange={(e) => {
            const on = e.target.checked;
            setSuggesting(on);
            if (on && suggestion === "" && suggestionSeed !== undefined)
              setSuggestion(suggestionSeed(file, Number(start), Number(end)) ?? "");
          }}
        />
        Suggest a change (replaces the commented lines)
      </label>
      {suggesting && (
        <textarea
          className="data"
          aria-label="Suggested change"
          rows={Math.min(12, Math.max(3, suggestion.split("\n").length + 1))}
          spellCheck={false}
          value={suggestion}
          onChange={(e) => setSuggestion(e.target.value)}
        />
      )}
      {problem !== null && (
        <p className="error" role="alert">
          {problem}
        </p>
      )}
      <div className="actions">
        <button type="submit">{submitLabel}</button>
        <button type="button" className="ghost" onClick={onCancel}>
          Cancel
        </button>
      </div>
    </form>
  );
}