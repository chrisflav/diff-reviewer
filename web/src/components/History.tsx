import { useCallback, useEffect, useRef, useState } from "react";
import { api, UnauthorizedError, type InlineComment, type Revision } from "../api";
import { rangeLabel } from "../review";
import {
  diffReviews,
  draftAndPosted,
  isEmptyDiff,
  lineDiff,
  readRevision,
  type ReviewDiff,
} from "../revisions";
import { CategoryTag, SeverityBadge } from "./Severity";

const authorLabel: Record<string, string> = {
  agent: "agent",
  person: "person",
  github: "GitHub",
};

const authorHelp: Record<string, string> = {
  agent: "what the agent submitted",
  person: "an edit made here",
  github: "what GitHub holds, once posted",
};

function revisionLabel(r: Revision): string {
  return `version ${r.version}, ${authorLabel[r.author] ?? r.author}, ${r.createdAt}`;
}

/** The pair being compared: by the versions they made, which name a job's revisions. */
interface Compare {
  from: number;
  to: number;
  /** Set by the draft-vs-posted button: say what the two are. */
  calibration: "posted" | "unposted" | null;
}

/**
 * The history of the job's review, oldest first and paged as the server pages it: each write,
 * by whom and when, and what changed between any two.
 */
export function History({
  jobId,
  jobVersion,
  onUnauthorized,
}: {
  jobId: string;
  /** The job's version: a new one may mean a new revision, so the first page is loaded again. */
  jobVersion: number;
  onUnauthorized: () => void;
}) {
  const [revs, setRevs] = useState<Revision[] | null>(null);
  const [next, setNext] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [compare, setCompare] = useState<Compare | null>(null);
  const latest = useRef(0);

  const fail = useCallback(
    (err: unknown) => {
      if (err instanceof UnauthorizedError) onUnauthorized();
      else setError(err instanceof Error ? err.message : String(err));
    },
    [onUnauthorized],
  );

  // The pages loaded so far are loaded again, so that what is shown stays one consistent list.
  const shown = useRef(1);
  useEffect(() => {
    const ticket = ++latest.current;
    const load = async () => {
      let items: Revision[] = [];
      let offset: number | null = 0;
      for (let p = 0; p < shown.current && offset !== null; p++) {
        const page = await api.revisions(jobId, 50, offset);
        items = [...items, ...page.items];
        offset = page.nextOffset;
      }
      return { items, offset };
    };
    load()
      .then(({ items, offset }) => {
        if (ticket !== latest.current) return;
        setRevs(items);
        setNext(offset);
        setError(null);
      })
      .catch((err: unknown) => {
        if (ticket === latest.current) fail(err);
      });
  }, [jobId, jobVersion, fail]);

  const more = () => {
    if (next === null) return;
    const ticket = ++latest.current;
    setBusy(true);
    api
      .revisions(jobId, 50, next)
      .then((page) => {
        if (ticket !== latest.current) return;
        shown.current++;
        setRevs((rs) => [...(rs ?? []), ...page.items]);
        setNext(page.nextOffset);
      })
      .catch(fail)
      .finally(() => setBusy(false));
  };

  /** Every page, for the draft-vs-posted comparison: what GitHub holds may be on the last. */
  const draftVsPosted = () => {
    const ticket = ++latest.current;
    setBusy(true);
    const load = async () => {
      let items = revs ?? [];
      let offset = revs === null ? 0 : next;
      while (offset !== null) {
        const page = await api.revisions(jobId, 200, offset);
        items = [...items, ...page.items];
        offset = page.nextOffset;
      }
      return items;
    };
    load()
      .then((items) => {
        if (ticket !== latest.current) return;
        setRevs(items);
        setNext(null);
        shown.current = Math.max(shown.current, Math.ceil(items.length / 50));
        const pair = draftAndPosted(items);
        if (pair === null) {
          setError("The history holds no draft by the agent: this review was not written by one.");
          return;
        }
        setError(null);
        setCompare({
          from: pair.draft.version,
          to: pair.final.version,
          calibration: pair.posted ? "posted" : "unposted",
        });
      })
      .catch(fail)
      .finally(() => setBusy(false));
  };

  const pair = revs === null ? null : draftAndPosted(revs);
  const byVersion = (v: number) => revs?.find((r) => r.version === v);
  const from = compare === null ? undefined : byVersion(compare.from);
  const to = compare === null ? undefined : byVersion(compare.to);

  return (
    <section aria-labelledby="history-h" className="history">
      <h2 id="history-h">History</h2>
      <p className="mute small-text">
        Every write of this review: the agent's submission, each edit, and what GitHub holds once it
        is posted. Comments are followed by their ids from one revision to the next.
      </p>
      {error !== null && (
        <p className="error" role="alert">
          {error}
        </p>
      )}
      {revs === null ? (
        error === null && <p className="mute">Loading the history…</p>
      ) : revs.length === 0 ? (
        <p className="mute">No revisions yet.</p>
      ) : (
        <>
          <div className="notice calibration">
            <p>
              <strong>The agent's draft beside what was posted</strong> is the comparison
              calibration learns from: what a person changed before the review went out.
            </p>
            <div className="actions">
              <button type="button" onClick={draftVsPosted} disabled={busy}>
                Compare the agent's draft with what was posted
              </button>
            </div>
            {pair !== null && !pair.posted && next === null && (
              <p className="mute small-text">
                Not posted yet: the latest revision stands in for what will be.
              </p>
            )}
          </div>
          <div className="table-scroll">
            <table className="revisions">
              <thead>
                <tr>
                  <th>Version</th>
                  <th>Author</th>
                  <th>Written</th>
                  <th>
                    <span className="sr-only">Compare</span>
                  </th>
                </tr>
              </thead>
              <tbody>
                {revs.map((r, i) => {
                  const prev = revs[i - 1];
                  return (
                    <tr
                      key={r.version}
                      className={
                        compare !== null && (compare.from === r.version || compare.to === r.version)
                          ? "picked"
                          : ""
                      }
                    >
                      <td className="data">{r.version}</td>
                      <td>
                        <span className={`author a-${r.author}`} title={authorHelp[r.author]}>
                          {authorLabel[r.author] ?? r.author}
                        </span>
                        {pair !== null && pair.draft.version === r.version && (
                          <span className="tag">draft</span>
                        )}
                        {r.author === "github" && <span className="tag">posted</span>}
                        {r.reviewError !== null && <span className="tag warn">unreadable</span>}
                      </td>
                      <td className="data mute">{r.createdAt}</td>
                      <td className="right">
                        {prev !== undefined && (
                          <button
                            type="button"
                            className="ghost small"
                            aria-label={`What version ${r.version} changed from version ${prev.version}`}
                            onClick={() =>
                              setCompare({ from: prev.version, to: r.version, calibration: null })
                            }
                          >
                            Changes
                          </button>
                        )}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
          {next !== null && (
            <div className="actions">
              <button type="button" className="ghost" onClick={more} disabled={busy}>
                Load newer revisions
              </button>
            </div>
          )}
          {revs.length > 1 && (
            <ComparePicker
              revs={revs}
              compare={compare}
              onCompare={(f, t) => setCompare({ from: f, to: t, calibration: null })}
            />
          )}
          {compare !== null && from !== undefined && to !== undefined && (
            <RevisionDiff
              from={from}
              to={to}
              calibration={compare.calibration}
              onClose={() => setCompare(null)}
            />
          )}
        </>
      )}
    </section>
  );
}

function ComparePicker({
  revs,
  compare,
  onCompare,
}: {
  revs: Revision[];
  compare: Compare | null;
  onCompare: (from: number, to: number) => void;
}) {
  const first = revs[0]?.version ?? 0;
  const last = revs[revs.length - 1]?.version ?? 0;
  const [from, setFrom] = useState(compare?.from ?? first);
  const [to, setTo] = useState(compare?.to ?? last);
  // A comparison picked elsewhere (a row's Changes, the draft button) shows here too.
  useEffect(() => {
    if (compare === null) return;
    setFrom(compare.from);
    setTo(compare.to);
  }, [compare]);
  return (
    <form
      className="inline compare"
      onSubmit={(e) => {
        e.preventDefault();
        onCompare(from, to);
      }}
    >
      <label>
        Compare{" "}
        <select value={from} onChange={(e) => setFrom(Number(e.target.value))}>
          {revs.map((r) => (
            <option key={r.version} value={r.version}>
              {revisionLabel(r)}
            </option>
          ))}
        </select>
      </label>
      <label>
        with{" "}
        <select value={to} onChange={(e) => setTo(Number(e.target.value))}>
          {revs.map((r) => (
            <option key={r.version} value={r.version}>
              {revisionLabel(r)}
            </option>
          ))}
        </select>
      </label>
      <button type="submit" className="ghost">
        Compare
      </button>
    </form>
  );
}

const fieldLabel: Record<string, string> = {
  place: "place",
  body: "text",
  suggestion: "suggestion",
  category: "category",
  severity: "severity",
};

/** What changed from one revision to another, all of it shown as text. */
function RevisionDiff({
  from,
  to,
  calibration,
  onClose,
}: {
  from: Revision;
  to: Revision;
  calibration: "posted" | "unposted" | null;
  onClose: () => void;
}) {
  const heading = useRef<HTMLHeadingElement>(null);
  // On the pair compared, not on the revision objects: a reload of the history makes new ones.
  useEffect(() => heading.current?.focus(), [from.version, to.version]);
  const a = readRevision(from);
  const b = readRevision(to);
  return (
    <section
      className={`revdiff${calibration !== null ? " calibration" : ""}`}
      aria-labelledby="revdiff-h"
    >
      <h3 id="revdiff-h" ref={heading} tabIndex={-1}>
        {calibration === "posted"
          ? "The agent's draft → what was posted"
          : calibration === "unposted"
            ? "The agent's draft → the latest revision (not posted yet)"
            : "Changes"}
      </h3>
      <p className="mute small-text">
        From {revisionLabel(from)}
        <br />
        to {revisionLabel(to)}
      </p>
      {typeof a === "string" || typeof b === "string" ? (
        <p className="error">
          {typeof a === "string" && `Version ${from.version}: ${a}. `}
          {typeof b === "string" && `Version ${to.version}: ${b}.`}
        </p>
      ) : (
        <DiffBody d={diffReviews(a, b)} />
      )}
      <div className="actions">
        <button type="button" className="ghost small" onClick={onClose}>
          Close the comparison
        </button>
      </div>
    </section>
  );
}

function DiffBody({ d }: { d: ReviewDiff }) {
  if (isEmptyDiff(d))
    return (
      <p>
        Nothing changed{d.unchanged > 0 && ` (${d.unchanged} comments, the same on both sides)`}.
      </p>
    );
  return (
    <>
      <ul className="revdiff-counts">
        <li>
          Decision:{" "}
          {d.decision === null ? (
            "unchanged"
          ) : (
            <>
              <span className="data">{d.decision.before}</span> →{" "}
              <span className="data">{d.decision.after}</span>
            </>
          )}
        </li>
        <li>Summary: {d.body === null ? "unchanged" : "changed"}</li>
        <li>
          Comments: {d.added.length} added, {d.removed.length} removed, {d.changed.length} changed,{" "}
          {d.unchanged} unchanged
        </li>
        {d.other.length > 0 && (
          <li>
            Other fields changed: <span className="data">{d.other.join(", ")}</span>
          </li>
        )}
      </ul>
      {d.guessed > 0 && (
        <p className="mute small-text">
          {d.guessed} {d.guessed === 1 ? "comment has" : "comments have"} no id (stored before ids
          existed), and {d.guessed === 1 ? "was" : "were"} paired by text or place.
        </p>
      )}
      {d.body !== null && (
        <>
          <h4>Summary</h4>
          <TextDiff before={d.body.before} after={d.body.after} label="The summary" />
        </>
      )}
      {d.removed.length > 0 && (
        <>
          <h4>Removed</h4>
          {d.removed.map((c, i) => (
            <ShownComment key={`r${i}`} c={c} kind="del" />
          ))}
        </>
      )}
      {d.added.length > 0 && (
        <>
          <h4>Added</h4>
          {d.added.map((c, i) => (
            <ShownComment key={`a${i}`} c={c} kind="add" />
          ))}
        </>
      )}
      {d.changed.length > 0 && (
        <>
          <h4>Changed</h4>
          {d.changed.map((ch, i) => (
            <div key={`c${i}`} className="comment">
              <header>
                <span className="where data">
                  {ch.after.file}, {rangeLabel(ch.after)}
                </span>
                <span className="labels">
                  <SeverityBadge severity={ch.after.severity} />
                  <CategoryTag category={ch.after.category} />
                </span>
              </header>
              <p className="small-text">
                Changed: {ch.fields.map((f) => fieldLabel[f] ?? f).join(", ")}
              </p>
              <ul className="changes">
                {ch.fields.includes("place") && (
                  <li>
                    Place:{" "}
                    <span className="data">{`${ch.before.file}, ${rangeLabel(ch.before)}`}</span> →{" "}
                    <span className="data">{`${ch.after.file}, ${rangeLabel(ch.after)}`}</span>
                  </li>
                )}
                {(["severity", "category"] as const)
                  .filter((f) => ch.fields.includes(f))
                  .map((f) => (
                    <li key={f}>
                      {f === "severity" ? "Severity" : "Category"}: {show(ch.before[f])} →{" "}
                      {show(ch.after[f])}
                    </li>
                  ))}
                {ch.fields
                  .filter(
                    (f) => !["place", "severity", "category", "body", "suggestion"].includes(f),
                  )
                  .map((f) => (
                    <li key={f}>
                      <span className="data">{f}</span>: {show(ch.before[f])} → {show(ch.after[f])}
                    </li>
                  ))}
              </ul>
              {ch.fields.includes("body") && (
                <TextDiff before={ch.before.body} after={ch.after.body} label="The comment" />
              )}
              {ch.fields.includes("suggestion") && (
                <>
                  <p className="mute small-text">Suggested change</p>
                  <TextDiff
                    before={ch.before.suggestion ?? ""}
                    after={ch.after.suggestion ?? ""}
                    label="The suggestion"
                    code
                  />
                </>
              )}
            </div>
          ))}
        </>
      )}
    </>
  );
}

function show(v: unknown): string {
  if (v === undefined || v === null) return "(none)";
  return typeof v === "string" ? v : JSON.stringify(v);
}

function ShownComment({ c, kind }: { c: InlineComment; kind: "add" | "del" }) {
  return (
    <article className={`comment shown-${kind}`}>
      <header>
        <span className="where data">
          <span className="sr-only">{kind === "add" ? "added: " : "removed: "}</span>
          {c.file}, {rangeLabel(c)}
        </span>
        <span className="labels">
          <SeverityBadge severity={c.severity} />
          <CategoryTag category={c.category} />
        </span>
      </header>
      {c.body !== "" && <p className="body">{c.body}</p>}
      {c.suggestion !== undefined && (
        <figure className="suggestion">
          <figcaption className="mute small-text">Suggested change</figcaption>
          <pre>{c.suggestion}</pre>
        </figure>
      )}
    </article>
  );
}

const mark = { same: " ", add: "+", del: "-" } as const;
const markLabel = { same: "", add: "added: ", del: "removed: " } as const;

/** Two texts as a line diff; each line says whether it was added or removed in words too. */
export function TextDiff({
  before,
  after,
  label,
  code = false,
}: {
  before: string;
  after: string;
  label: string;
  code?: boolean;
}) {
  const parts = lineDiff(before, after);
  return (
    <div
      className={`textdiff${code ? " data" : ""}`}
      role="group"
      aria-label={`${label}, before and after`}
    >
      {parts.map((p, i) => (
        <div key={i} className={`tl ${p.kind}`}>
          <span className="sign" aria-hidden="true">
            {mark[p.kind]}
          </span>
          <span className="sr-only">{markLabel[p.kind]}</span>
          {p.text === "" ? " " : p.text}
        </div>
      ))}
    </div>
  );
}