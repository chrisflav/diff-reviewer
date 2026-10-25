import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Link, useParams } from "react-router-dom";
import {
  api,
  ApiError,
  canEdit,
  canPost,
  nextStatuses,
  UnauthorizedError,
  type Decision,
  type InlineComment,
  type Job,
  type JobDiff,
  type JobStatus,
  type Review,
} from "../api";
import { CommentCard, type CommentActions } from "../components/Comments";
import { DiffView, type Selection } from "../components/DiffView";
import { parseDiff, type DiffFile } from "../diff";
import {
  nextKey,
  parseReview,
  placeComments,
  reviewProblem,
  toLocal,
  toReview,
  type LocalComment,
  type LocalReview,
} from "../review";
import { useLoad } from "../useLoad";

const actionLabel: Partial<Record<JobStatus, string>> = {
  approved: "Approve",
  rejected: "Reject",
  stale: "Mark stale",
  draft: "Back to draft",
  pending: "Retry",
};

const decisionLabel = {
  comment: "Comment",
  approve: "Approve",
  request_changes: "Request changes",
} as const;

const emptyReview: Review = { decision: "comment", body: "", comments: [] };

/** Unsaved edits, and the job version they were made against: a save sends that version. */
interface Edits {
  version: number;
  review: LocalReview;
}

export function JobPage({ onUnauthorized }: { onUnauthorized: () => void }) {
  const { id = "" } = useParams();
  const fetchJob = useCallback(() => api.job(id), [id]);
  const {
    data: job,
    error,
    reload,
    setError,
    setData: setJob,
  } = useLoad<Job>(fetchJob, onUnauthorized);
  const [edits, setEdits] = useState<Edits | null>(null);
  const [selection, setSelection] = useState<Selection | null>(null);
  // A 409: the job is not what this page last saw. Shown until the person picks a way on.
  const [conflict, setConflict] = useState<string | null>(null);
  // The job a "reload, keep my edits" left from; the edits move onto the next one that lands.
  const [rebaseFrom, setRebaseFrom] = useState<Job | null>(null);
  const [busy, setBusy] = useState(false);
  const [confirmPost, setConfirmPost] = useState(false);

  const saved = useMemo(() => toLocal(job?.review ?? emptyReview), [job?.review]);
  const current = edits?.review ?? saved;

  // The edit actions are stable, so that the diff's files need not redraw when they are made;
  // they read the latest job through a ref.
  const base = useRef({ version: 0, review: saved });
  base.current = { version: job?.version ?? 0, review: saved };
  const modify = useCallback((f: (r: LocalReview) => LocalReview) => {
    setEdits((e) =>
      e !== null
        ? { ...e, review: f(e.review) }
        : { version: base.current.version, review: f(base.current.review) },
    );
  }, []);

  const actions = useMemo<CommentActions>(
    () => ({
      add: (c: InlineComment) => {
        modify((r) => ({ ...r, comments: [...r.comments, { ...c, key: nextKey(r) }] }));
        setSelection(null);
      },
      update: (key: number, c: InlineComment) =>
        modify((r) => ({
          ...r,
          comments: r.comments.map((old) => (old.key === key ? { ...c, key } : old)),
        })),
      remove: (key: number) =>
        modify((r) => ({ ...r, comments: r.comments.filter((c) => c.key !== key) })),
      cancelSelection: () => setSelection(null),
    }),
    [modify],
  );

  useEffect(() => {
    if (rebaseFrom === null || job === null || job === rebaseFrom) return;
    setEdits((e) => (e === null ? null : { ...e, version: job.version }));
    setRebaseFrom(null);
  }, [job, rebaseFrom]);

  // Leaving the page with unsaved edits asks first. Links inside the app do not; the save bar
  // stays in view to make up for it.
  useEffect(() => {
    if (edits === null) return;
    const warn = (e: BeforeUnloadEvent) => e.preventDefault();
    window.addEventListener("beforeunload", warn);
    return () => window.removeEventListener("beforeunload", warn);
  }, [edits]);

  if (job === null)
    return error !== null ? <p className="error">{error}</p> : <p className="mute">Loading…</p>;

  const editable = canEdit(job.status) && job.reviewError === null;
  const dirty = edits !== null;

  const fail = (err: unknown) => {
    if (err instanceof UnauthorizedError) onUnauthorized();
    else if (err instanceof ApiError && err.status === 409) setConflict(err.message);
    else setError(err instanceof Error ? err.message : String(err));
  };

  const run = (p: Promise<Job>, after?: () => void) => {
    setBusy(true);
    setError(null);
    p.then((j) => {
      setJob(j);
      after?.();
    })
      .catch(fail)
      .finally(() => setBusy(false));
  };

  const save = () => {
    if (edits === null) return;
    const review = toReview(edits.review);
    const problem = reviewProblem(review);
    if (problem !== null) {
      setError(problem);
      return;
    }
    run(api.putReview(job.id, edits.version, review), () => {
      setEdits(null);
      setSelection(null);
    });
  };

  const discard = () => {
    setEdits(null);
    setSelection(null);
    setError(null);
  };

  const reloadDiscarding = () => {
    discard();
    setConflict(null);
    reload();
  };

  const reloadKeeping = () => {
    setConflict(null);
    setRebaseFrom(job);
    reload();
  };

  const moves = nextStatuses(job.status);

  return (
    <>
      <p className="crumbs">
        <Link to="/">Reviews</Link>
      </p>
      <h1>
        {job.owner}/{job.name}#{job.prNumber}{" "}
        <span className={`status s-${job.status}`}>{job.status}</span>
      </h1>
      <dl className="facts">
        <dt>Job</dt>
        <dd className="data">{job.id}</dd>
        <dt>Head</dt>
        <dd className="data">{job.headSha ?? "—"}</dd>
        <dt>Queue entry</dt>
        <dd className="data">{job.queueEntry ?? "—"}</dd>
        <dt>Updated</dt>
        <dd className="data">{job.updatedAt}</dd>
      </dl>

      {job.status === "failed" && (
        <p className="notice danger-notice">
          The agent's run ended without submitting a review. Retry puts the job back in the queue.
        </p>
      )}
      {error !== null && (
        <p className="error" role="alert">
          {error}
        </p>
      )}
      {conflict !== null && (
        <div className="notice warn-notice" role="alert">
          <p>The job changed since this page loaded it, so nothing was saved: {conflict}</p>
          {dirty ? (
            <>
              <p>
                Your edits are still here. Reload the job, and either drop them or keep them to save
                over the new version.
              </p>
              <div className="actions">
                <button type="button" onClick={reloadDiscarding}>
                  Reload, discard my edits
                </button>
                <button type="button" className="ghost" onClick={reloadKeeping}>
                  Reload, keep my edits
                </button>
              </div>
            </>
          ) : (
            <div className="actions">
              <button type="button" onClick={reloadDiscarding}>
                Reload
              </button>
            </div>
          )}
        </div>
      )}

      {(moves.length > 0 || canPost(job.status)) && (
        <div className="actions">
          {moves.map((s) => (
            <button
              key={s}
              type="button"
              className={s === "approved" || s === "pending" ? "" : "ghost"}
              disabled={busy || dirty}
              onClick={() => run(api.setStatus(job.id, job.version, s))}
            >
              {actionLabel[s] ?? s}
            </button>
          ))}
          {canPost(job.status) && (
            <button
              type="button"
              disabled={busy || dirty || confirmPost}
              onClick={() => setConfirmPost(true)}
            >
              Post to GitHub…
            </button>
          )}
          {dirty && <span className="mute small-text">Save or discard your edits first.</span>}
        </div>
      )}
      {confirmPost && canPost(job.status) && (
        <div className="notice" role="dialog" aria-labelledby="post-q">
          <p id="post-q">
            Post this review to {job.owner}/{job.name}#{job.prNumber}
            {job.headSha !== null && (
              <>
                {" "}
                at <span className="data">{job.headSha.slice(0, 12)}</span>
              </>
            )}
            ? It is posted under the operator's GitHub account, and cannot be taken back from here.
          </p>
          <div className="actions">
            <button
              type="button"
              autoFocus
              disabled={busy}
              onClick={() => run(api.post(job.id, job.version), () => setConfirmPost(false))}
            >
              Post review
            </button>
            <button type="button" className="ghost" onClick={() => setConfirmPost(false)}>
              Cancel
            </button>
          </div>
        </div>
      )}

      <h2>Review</h2>
      {job.reviewError !== null ? (
        <p className="error">The stored review cannot be read by this version: {job.reviewError}</p>
      ) : job.review === null && !editable ? (
        <p className="mute">No review yet.</p>
      ) : (
        <Summary review={current} editable={editable} modify={modify} />
      )}

      {job.reviewError === null && (
        <DiffSection
          job={job}
          comments={current.comments}
          editable={editable}
          selection={selection}
          setSelection={setSelection}
          actions={actions}
          onUnauthorized={onUnauthorized}
        />
      )}

      {(editable || dirty) && <RawEditor review={current} modify={modify} />}

      {dirty && (
        <div className="savebar" role="region" aria-label="Unsaved changes">
          <span>
            Unsaved changes.
            {!editable
              ? ` A ${job.status} job's review is not edited; discard, or copy them from Edit as JSON first.`
              : job.status !== "draft" &&
                job.status !== "pending" &&
                " Saving makes the job a draft again."}
          </span>
          <span className="actions">
            <button type="button" onClick={save} disabled={busy || !editable}>
              Save review
            </button>
            <button type="button" className="ghost" onClick={discard} disabled={busy}>
              Discard
            </button>
          </span>
        </div>
      )}
    </>
  );
}

function Summary({
  review,
  editable,
  modify,
}: {
  review: LocalReview;
  editable: boolean;
  modify: (f: (r: LocalReview) => LocalReview) => void;
}) {
  if (!editable)
    return (
      <section className="review">
        <p>
          <span className={`decision d-${review.decision}`}>{decisionLabel[review.decision]}</span>
        </p>
        {review.body !== "" && <p className="body">{review.body}</p>}
      </section>
    );
  return (
    <section className="review summary-edit">
      <label>
        Decision
        <select
          value={review.decision}
          onChange={(e) => {
            const decision = e.target.value as Decision;
            modify((r) => ({ ...r, decision }));
          }}
        >
          {Object.entries(decisionLabel).map(([k, v]) => (
            <option key={k} value={k}>
              {v}
            </option>
          ))}
        </select>
      </label>
      <label>
        Summary
        <textarea
          rows={Math.min(16, Math.max(4, review.body.split("\n").length + 1))}
          value={review.body}
          onChange={(e) => {
            const body = e.target.value;
            modify((r) => ({ ...r, body }));
          }}
        />
      </label>
    </section>
  );
}

function DiffSection({
  job,
  comments,
  editable,
  selection,
  setSelection,
  actions,
  onUnauthorized,
}: {
  job: Job;
  comments: LocalComment[];
  editable: boolean;
  selection: Selection | null;
  setSelection: (f: (s: Selection | null) => Selection | null) => void;
  actions: CommentActions;
  onUnauthorized: () => void;
}) {
  const { id, headSha } = job;
  // Fetched again when the head moves, and only then: a status move leaves the diff as it was.
  const fetchDiff = useCallback(() => api.diff(id), [id, headSha]);
  const { data, error } = useLoad<JobDiff>(fetchDiff, onUnauthorized);
  const files = useMemo<DiffFile[] | null>(
    () => (data === null ? null : parseDiff(data.diff)),
    [data],
  );
  const placement = useMemo(() => placeComments(files ?? [], comments), [files, comments]);

  const onSelect = useCallback(
    (file: string, line: number, extend: boolean) =>
      setSelection((s) => {
        if (extend && s !== null && s.file === file)
          return {
            file,
            anchor: s.anchor,
            start: Math.min(s.anchor, line),
            end: Math.max(s.anchor, line),
          };
        if (s !== null && s.file === file && s.start === line && s.end === line) return null;
        return { file, start: line, end: line, anchor: line };
      }),
    [setSelection],
  );

  // A range typed into the form moves the selection only when the diff shows both ends, since
  // the form lives under the last line.
  const onRangeChange = useCallback(
    (start: number, end: number) =>
      setSelection((s) => {
        if (s === null || files === null) return s;
        const f = files.find((x) => x.newPath === s.file);
        const shown = (n: number) => f?.hunks.some((h) => h.lines.some((l) => l.newLine === n));
        return shown(start) === true && shown(end) === true
          ? { ...s, start, end, anchor: start }
          : s;
      }),
    [files, setSelection],
  );

  const suggestionSeed = useCallback(
    (file: string, start: number, end: number): string | null => {
      const f = files?.find((x) => x.newPath === file);
      if (f === undefined) return null;
      const byLine = new Map<number, string>();
      for (const h of f.hunks)
        for (const l of h.lines) if (l.newLine !== null) byLine.set(l.newLine, l.text);
      const out: string[] = [];
      for (let n = start; n <= end; n++) {
        const t = byLine.get(n);
        if (t === undefined) return null;
        out.push(t);
      }
      return out.join("\n");
    },
    [files],
  );

  return (
    <>
      <h2>Diff</h2>
      {error !== null ? (
        <p className="error">The diff could not be loaded: {error}</p>
      ) : files === null ? (
        <p className="mute">Loading the diff…</p>
      ) : (
        <>
          {data !== null && job.headSha !== null && data.headSha !== job.headSha && (
            <p className="notice warn-notice">
              This diff is of <span className="data">{data.headSha.slice(0, 12)}</span>, not of the
              job's head <span className="data">{job.headSha.slice(0, 12)}</span>.
            </p>
          )}
          <DiffView
            files={files}
            placement={placement}
            editable={editable}
            selection={selection}
            onSelect={onSelect}
            onRangeChange={onRangeChange}
            actions={actions}
            suggestionSeed={suggestionSeed}
          />
        </>
      )}

      {(placement.outside.length > 0 || (files === null && comments.length > 0)) && (
        <section aria-labelledby="outside-h">
          <h2 id="outside-h">{files === null ? "Comments" : "Outside the diff"}</h2>
          <p className="mute small-text">
            {files === null
              ? "Listed by place until the diff is shown."
              : "These comments name lines the diff does not show, or a file it does not touch. GitHub refuses such comments: move them onto lines of the diff, or delete them, before posting."}
          </p>
          {(files === null ? comments : placement.outside).map((c) => (
            <CommentCard
              key={c.key}
              comment={c}
              editable={editable}
              actions={actions}
              showFile
              suggestionSeed={suggestionSeed}
            />
          ))}
        </section>
      )}
    </>
  );
}

/** The review as JSON, for what the forms do not do: moving a comment to another file, bulk edits. */
function RawEditor({
  review,
  modify,
}: {
  review: LocalReview;
  modify: (f: (r: LocalReview) => LocalReview) => void;
}) {
  const [open, setOpen] = useState(false);
  const [text, setText] = useState("");
  const [problem, setProblem] = useState<string | null>(null);

  const apply = () => {
    const r = parseReview(text);
    if (typeof r === "string") {
      setProblem(r);
      return;
    }
    setProblem(null);
    modify(() => toLocal(r));
  };

  return (
    <details
      open={open}
      onToggle={(e) => {
        const now = e.currentTarget.open;
        if (now === open) return;
        setOpen(now);
        if (now) {
          setText(JSON.stringify(toReview(review), null, 2));
          setProblem(null);
        }
      }}
    >
      <summary>Edit as JSON</summary>
      <p className="mute small-text">
        The review with the edits so far. Applying replaces them; Save review then sends it.
      </p>
      <textarea
        className="data"
        aria-label="The review as JSON"
        rows={18}
        spellCheck={false}
        value={text}
        onChange={(e) => setText(e.target.value)}
      />
      {problem !== null && (
        <p className="error" role="alert">
          {problem}
        </p>
      )}
      <div className="actions">
        <button type="button" onClick={apply}>
          Apply JSON
        </button>
        <button
          type="button"
          className="ghost"
          onClick={() => setText(JSON.stringify(toReview(review), null, 2))}
        >
          Reset to the current edits
        </button>
      </div>
    </details>
  );
}