import { useId, useState, type FormEvent } from "react";
import type { InlineComment } from "../api";
import { commentProblem, rangeLabel, type LocalComment } from "../review";

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

  if (editing)
    return (
      <div className="comment">
        <CommentForm
          initial={comment}
          showFile={showFile}
          submitLabel="Apply"
          onSubmit={(c) => {
            actions.update(comment.key, c);
            setEditing(false);
          }}
          onCancel={() => setEditing(false)}
          {...(suggestionSeed === undefined ? {} : { suggestionSeed })}
        />
      </div>
    );

  return (
    <article className="comment" aria-label={`Comment on ${comment.file} ${rangeLabel(comment)}`}>
      <header>
        <span className="where data">
          {showFile && `${comment.file}, `}
          {rangeLabel(comment)}
        </span>
        {editable && (
          <span className="tools">
            <button type="button" className="ghost small" onClick={() => setEditing(true)}>
              Edit
            </button>
            <button
              type="button"
              className="ghost small danger"
              onClick={() => actions.remove(comment.key)}
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
  const [problem, setProblem] = useState<string | null>(null);

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
    return c;
  };

  const submit = (e: FormEvent) => {
    e.preventDefault();
    const c = build();
    const p = commentProblem(c);
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