import { useState } from "react";
import { severities, type Severity } from "../api";
import {
  filterComments,
  KEY,
  rangeLabel,
  type CommentFilter,
  type CommentSort,
  type LocalComment,
} from "../review";
import { CategoryTag, SeverityBadge } from "./Severity";

/**
 * The review's comments as one list, to be read by severity or category: filtered and sorted
 * here, each a way to its place in the diff. The diff itself keeps every comment where it is.
 */
export function CommentList({
  comments,
  onShow,
}: {
  comments: LocalComment[];
  /** Bring the comment into view where the diff (or the list outside it) has it. */
  onShow: (c: LocalComment) => void;
}) {
  const [filter, setFilter] = useState<CommentFilter>({ severities: [], category: "" });
  const [sort, setSort] = useState<CommentSort>("severity");
  if (comments.length === 0) return null;

  const categories = [
    ...new Set(comments.flatMap((c) => (c.category === undefined ? [] : [c.category]))),
  ].sort();
  const uncategorised = comments.some((c) => c.category === undefined);
  const shown = filterComments(comments, filter, sort);
  const counts = new Map<Severity | "none", number>();
  for (const c of comments) {
    const s = severities.includes(c.severity as Severity) ? (c.severity as Severity) : "none";
    counts.set(s, (counts.get(s) ?? 0) + 1);
  }
  const toggle = (s: Severity | "none", on: boolean) =>
    setFilter((f) => ({
      ...f,
      severities: on ? [...f.severities, s] : f.severities.filter((x) => x !== s),
    }));

  return (
    <details className="comment-list">
      <summary>
        All comments ({comments.length}
        {[...severities]
          .reverse()
          .map((s) => ((counts.get(s) ?? 0) > 0 ? `, ${counts.get(s)} ${s}` : ""))}
        )
      </summary>
      <div className="list-tools">
        <fieldset className="sev-filter">
          <legend>Severity</legend>
          {[...[...severities].reverse(), "none" as const].map((s) => (
            <label key={s} className="check">
              <input
                type="checkbox"
                checked={filter.severities.includes(s)}
                onChange={(e) => toggle(s, e.target.checked)}
              />
              {s === "none" ? "no severity" : s} ({counts.get(s) ?? 0})
            </label>
          ))}
        </fieldset>
        <label>
          Category{" "}
          {/* Options by position, not by name: any name is a category's, none stands for another. */}
          <select
            value={
              filter.category === null
                ? "none"
                : filter.category === ""
                  ? "all"
                  : String(categories.indexOf(filter.category))
            }
            onChange={(e) => {
              const v = e.target.value;
              const category =
                v === "none" ? null : v === "all" ? "" : (categories[Number(v)] ?? "");
              setFilter((f) => ({ ...f, category }));
            }}
          >
            <option value="all">all</option>
            {categories.map((c, i) => (
              <option key={c} value={String(i)}>
                {c}
              </option>
            ))}
            {uncategorised && <option value="none">(no category)</option>}
          </select>
        </label>
        <label>
          Sort by{" "}
          <select value={sort} onChange={(e) => setSort(e.target.value as CommentSort)}>
            <option value="severity">severity, most first</option>
            <option value="category">category</option>
            <option value="place">file and line</option>
          </select>
        </label>
      </div>
      <p className="mute small-text" role="status">
        {shown.length === comments.length
          ? `Showing all ${comments.length}.`
          : `Showing ${shown.length} of ${comments.length}.`}
      </p>
      <ol className="overview">
        {shown.map((c) => (
          <li key={c[KEY]}>
            <span className="labels">
              <SeverityBadge severity={c.severity} />
              <CategoryTag category={c.category} />
            </span>
            <button type="button" className="ghost small where data" onClick={() => onShow(c)}>
              {c.file}, {rangeLabel(c)}
            </button>
            <span className="excerpt">{c.body === "" ? "(a suggested change)" : c.body}</span>
          </li>
        ))}
      </ol>
    </details>
  );
}