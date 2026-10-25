import type { Severity } from "../api";
import { severityRank } from "../review";

const severityHelp: Record<Severity, string> = {
  nit: "may be ignored",
  minor: "worth fixing",
  major: "should be fixed",
  blocker: "must be fixed before merging",
};

/**
 * A comment's severity. The word says it, and a meter of filled squares and a border that grows
 * heavier with it say it again: never the colour alone.
 */
export function SeverityBadge({ severity }: { severity: unknown }) {
  const rank = severityRank(severity);
  if (rank < 0) return null;
  const s = severity as Severity;
  return (
    <span className={`sev sev-${s}`} title={`${s}: ${severityHelp[s]}`}>
      <span className="meter" aria-hidden="true">
        {"■".repeat(rank + 1)}
        {"□".repeat(3 - rank)}
      </span>
      <span className="sr-only">severity </span>
      {s}
    </span>
  );
}

/** A comment's category, as text: an agent or a person typed it. */
export function CategoryTag({ category }: { category: unknown }) {
  if (typeof category !== "string") return null;
  return (
    <span className="tag cat">
      <span className="sr-only">category </span>
      {category}
    </span>
  );
}

export { severityHelp };