import {
  memo,
  useCallback,
  useRef,
  useState,
  type KeyboardEvent,
  type MouseEvent,
  type ReactNode,
} from "react";
import { displayPath, lineCount, type DiffFile, type DiffLine } from "../diff";
import { commentsIn, type LocalComment, type Placement } from "../review";
import { CommentCard, CommentForm, type CommentActions } from "./Comments";

/** Lines over which a file starts folded, so that a large diff opens on its outline. */
export const FOLD_LINES = 400;
/** Lines of the whole diff over which only the files carrying comments start open. */
export const FOLD_TOTAL = 3000;

/** The new-side lines picked for a new comment; `anchor` is where a shift-click extends from. */
export interface Selection {
  file: string;
  start: number;
  end: number;
  anchor: number;
}

export function DiffView({
  files,
  placement,
  editable,
  selection,
  onSelect,
  onRangeChange,
  actions,
  suggestionSeed,
}: {
  files: DiffFile[];
  placement: Placement;
  editable: boolean;
  selection: Selection | null;
  onSelect: (file: string, line: number, extend: boolean) => void;
  onRangeChange: (start: number, end: number) => void;
  actions: CommentActions;
  suggestionSeed: (file: string, start: number, end: number) => string | null;
}) {
  const total = files.reduce((n, f) => n + lineCount(f), 0);
  const [open, setOpen] = useState<Map<number, boolean>>(() => new Map());
  const [wrap, setWrap] = useState(true);

  const isOpen = (f: DiffFile, i: number): boolean => {
    const set = open.get(i);
    if (set !== undefined) return set;
    if (f.binary || f.hunks.length === 0) return false;
    if (lineCount(f) > FOLD_LINES) return false;
    return total <= FOLD_TOTAL || commentsIn(placement, f) > 0;
  };

  const setAll = (to: boolean) => setOpen(new Map(files.map((_, i) => [i, to])));
  const toggle = useCallback((i: number, to: boolean) => setOpen((m) => new Map(m).set(i, to)), []);

  if (files.length === 0) return <p className="mute">The diff is empty.</p>;

  return (
    <section className="diff" aria-label="Diff">
      <div className="diff-tools">
        <span className="mute">
          {files.length} {files.length === 1 ? "file" : "files"}
        </span>
        <label className="check">
          <input type="checkbox" checked={wrap} onChange={(e) => setWrap(e.target.checked)} />
          Wrap long lines
        </label>
        <button type="button" className="ghost small" onClick={() => setAll(true)}>
          Expand all
        </button>
        <button type="button" className="ghost small" onClick={() => setAll(false)}>
          Collapse all
        </button>
      </div>
      {editable && (
        <p className="mute small-text">
          Pick a line number on the new side to comment on it; shift-click another to cover a range.
          With the keyboard: Tab to a file's line numbers, the arrow keys move between them, Enter
          picks one.
        </p>
      )}
      {files.map((f, i) => {
        const path = displayPath(f);
        const sel = selection !== null && selection.file === f.newPath ? selection : null;
        return (
          <FileView
            key={i}
            index={i}
            file={f}
            open={isOpen(f, i)}
            onToggle={toggle}
            wrap={wrap}
            byLine={f.newPath === null ? undefined : placement.anchored.get(path)}
            covered={f.newPath === null ? undefined : placement.covered.get(path)}
            split={placement.split}
            commentCount={commentsIn(placement, f)}
            editable={editable}
            selection={sel}
            onSelect={onSelect}
            onRangeChange={onRangeChange}
            actions={actions}
            suggestionSeed={suggestionSeed}
          />
        );
      })}
    </section>
  );
}

const changeLabel = {
  modified: "",
  added: "added",
  deleted: "deleted",
  renamed: "renamed",
  copied: "copied",
} as const;

interface FileProps {
  index: number;
  file: DiffFile;
  open: boolean;
  onToggle: (index: number, open: boolean) => void;
  wrap: boolean;
  byLine: Map<number, LocalComment[]> | undefined;
  covered: Set<number> | undefined;
  split: Set<number>;
  commentCount: number;
  editable: boolean;
  selection: Selection | null;
  onSelect: (file: string, line: number, extend: boolean) => void;
  onRangeChange: (start: number, end: number) => void;
  actions: CommentActions;
  suggestionSeed: (file: string, start: number, end: number) => string | null;
}

// Memoised: a keystroke or a pick in one file must not redraw every other file of a long diff.
const FileView = memo(function FileView(props: FileProps) {
  const { index, file, open, onToggle, wrap, commentCount } = props;
  const path = displayPath(file);
  const adds = file.hunks.reduce((n, h) => n + h.lines.filter((l) => l.kind === "add").length, 0);
  const dels = file.hunks.reduce((n, h) => n + h.lines.filter((l) => l.kind === "del").length, 0);
  const renamedFrom =
    (file.change === "renamed" || file.change === "copied") && file.oldPath !== null
      ? file.oldPath
      : null;

  return (
    <details
      className="file"
      open={open}
      onToggle={(e) => {
        // `toggle` also fires when React sets `open`; only a change is news.
        if (e.currentTarget.open !== open) onToggle(index, e.currentTarget.open);
      }}
    >
      <summary>
        <span className="path data">{path}</span>
        {renamedFrom !== null && <span className="mute data small-text">from {renamedFrom}</span>}
        {changeLabel[file.change] !== "" && <span className="tag">{changeLabel[file.change]}</span>}
        <span className="counts data">
          <span className="plus">+{adds}</span> <span className="minus">−{dels}</span>
        </span>
        {commentCount > 0 && (
          <span className="tag">
            {commentCount} {commentCount === 1 ? "comment" : "comments"}
          </span>
        )}
      </summary>
      {open &&
        (file.binary ? (
          <p className="mute file-note">Binary file; not shown.</p>
        ) : file.hunks.length === 0 ? (
          <p className="mute file-note">No changed lines (a mode change or a pure rename).</p>
        ) : (
          <div className={wrap ? "code wrap" : "code scroll"}>
            <FileTable {...props} />
          </div>
        ))}
    </details>
  );
});

function FileTable({
  file,
  byLine,
  covered,
  split,
  editable,
  selection,
  onSelect,
  onRangeChange,
  actions,
  suggestionSeed,
}: FileProps) {
  const path = displayPath(file);
  const commentable = editable && file.newPath !== null;
  const first = file.hunks.flatMap((h) => h.lines).find((l) => l.newLine !== null)?.newLine ?? null;
  // One line number per file is a tab stop (a roving tab index); the arrows move it.
  const [focusLine, setFocusLine] = useState<number | null>(null);
  const tabLine = focusLine ?? selection?.end ?? first;
  const body = useRef<HTMLTableSectionElement>(null);
  // Closing the comment form puts focus back on the line it was opened from, not on the page.
  const refocus = (line: number) =>
    requestAnimationFrame(() =>
      body.current?.querySelector<HTMLButtonElement>(`button.lnum[data-line="${line}"]`)?.focus(),
    );

  const onKeyDown = (e: KeyboardEvent<HTMLTableSectionElement>) => {
    if (e.key !== "ArrowDown" && e.key !== "ArrowUp" && e.key !== "Home" && e.key !== "End") return;
    const target = e.target as HTMLElement;
    if (!target.matches("button.lnum")) return;
    const all = Array.from(e.currentTarget.querySelectorAll<HTMLButtonElement>("button.lnum"));
    const at = all.indexOf(target as HTMLButtonElement);
    const to =
      e.key === "Home"
        ? 0
        : e.key === "End"
          ? all.length - 1
          : at + (e.key === "ArrowDown" ? 1 : -1);
    const next = all[Math.max(0, Math.min(all.length - 1, to))];
    if (next === undefined) return;
    e.preventDefault();
    setFocusLine(Number(next.dataset.line));
    next.focus();
  };

  const rows: ReactNode[] = [];
  file.hunks.forEach((h, hi) => {
    rows.push(
      <tr key={`h${hi}`} className="hunk">
        <td colSpan={3} className="data">
          {h.header}
        </td>
      </tr>,
    );
    h.lines.forEach((l, li) => {
      const n = l.newLine;
      const selected =
        selection !== null && n !== null && n >= selection.start && n <= selection.end;
      rows.push(
        <Row
          key={`l${hi}.${li}`}
          line={l}
          path={path}
          commentable={commentable}
          tabbable={n !== null && n === tabLine}
          covered={n !== null && covered?.has(n) === true}
          selected={selected}
          onPick={(e) => {
            if (n === null) return;
            setFocusLine(n);
            onSelect(file.newPath ?? path, n, e.shiftKey);
          }}
        />,
      );
      if (n === null) return;
      const here = byLine?.get(n);
      const composing = selection !== null && selection.end === n;
      if (here !== undefined)
        rows.push(
          <tr key={`c${n}`} className="anchor">
            <td colSpan={3}>
              {here.map((c) => (
                <CommentCard
                  key={c.key}
                  comment={c}
                  editable={editable}
                  actions={actions}
                  split={split.has(c.key)}
                  suggestionSeed={suggestionSeed}
                />
              ))}
            </td>
          </tr>,
        );
      if (composing)
        // Keyed by itself, so it keeps what was typed while a shift-click moves it.
        rows.push(
          <tr key="composer" className="anchor composer">
            <td colSpan={3}>
              <div className="comment">
                <CommentForm
                  initial={{
                    file: selection.file,
                    start_line: selection.start,
                    end_line: selection.end,
                    body: "",
                  }}
                  showFile={false}
                  submitLabel="Add comment"
                  onSubmit={(c) => {
                    actions.add(c);
                    refocus(n);
                  }}
                  onCancel={() => {
                    actions.cancelSelection();
                    refocus(n);
                  }}
                  onRangeChange={onRangeChange}
                  suggestionSeed={suggestionSeed}
                />
              </div>
            </td>
          </tr>,
        );
    });
  });

  return (
    <table className="lines">
      <colgroup>
        <col className="num" />
        <col className="num" />
        <col />
      </colgroup>
      <tbody ref={body} onKeyDown={onKeyDown}>
        {rows}
      </tbody>
    </table>
  );
}

const sign = { context: " ", add: "+", del: "-" } as const;
const kindLabel = { context: "", add: "added", del: "removed" } as const;

function Row({
  line,
  path,
  commentable,
  tabbable,
  covered,
  selected,
  onPick,
}: {
  line: DiffLine;
  path: string;
  commentable: boolean;
  tabbable: boolean;
  covered: boolean;
  selected: boolean;
  onPick: (e: MouseEvent) => void;
}) {
  const n = line.newLine;
  const cls = ["ln", line.kind, covered ? "covered" : "", selected ? "selected" : ""]
    .filter((c) => c !== "")
    .join(" ");
  return (
    <tr className={cls}>
      <td className="num data">{line.oldLine ?? ""}</td>
      <td className="num data">
        {n === null ? (
          ""
        ) : commentable ? (
          <button
            type="button"
            className="lnum"
            data-line={n}
            tabIndex={tabbable ? 0 : -1}
            aria-pressed={selected}
            aria-label={`Comment on line ${n} of ${path}${kindLabel[line.kind] === "" ? "" : ` (${kindLabel[line.kind]})`}`}
            onClick={onPick}
          >
            {n}
          </button>
        ) : (
          n
        )}
      </td>
      <td className="text data">
        <span className="sign">{sign[line.kind]}</span>
        {line.text}
        {line.noNewline && <span className="mute small-text"> (no newline at end of file)</span>}
      </td>
    </tr>
  );
}