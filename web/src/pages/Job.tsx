import { useCallback, useContext, useEffect, useMemo, useRef, useState } from "react";
import { Link, useBlocker, useParams } from "react-router-dom";
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
import { CommentCard, FormsContext, type CommentActions } from "../components/Comments";
import { DiffView, type Selection } from "../components/DiffView";
import { parseDiff, type DiffFile } from "../diff";
import {
  conflictId,
  freshKeys,
  fromJson,
  KEY,
  mergeComment,
  placeComments,
  rangeLabel,
  rebase,
  resolve,
  reviewProblem,
  sameReview,
  toLocal,
  toReview,
  type Conflict,
  type LocalComment,
  type LocalReview,
  type Placement,
} from "../review";
import { dropStash, stash, unstash, type Edits, type Stashed } from "../stash";
import { UnsavedContext } from "../unsaved";
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

type Pick = "mine" | "theirs";

/** Edits moved onto a newer version of the job, and what that left for the person to settle. */
interface Rebased {
  from: number;
  to: number;
  conflicts: Conflict[];
  picks: Record<string, Pick>;
  /** The edits as they were before the move: what is kept in storage until all is settled. */
  source: Edits;
}

type Modify = (f: (r: LocalReview, base: LocalReview) => LocalReview) => void;

export function JobPage({ onUnauthorized }: { onUnauthorized: () => void }) {
  const { id = "" } = useParams();
  // Keyed by the job: nothing one job's page holds (edits above all) may reach another's.
  return <JobView key={id} id={id} onUnauthorized={onUnauthorized} />;
}

function JobView({ id, onUnauthorized }: { id: string; onUnauthorized: () => void }) {
  const fetchJob = useCallback(() => api.job(id), [id]);
  const {
    data: job,
    error,
    reload,
    setError,
    setData: setJob,
  } = useLoad<Job>(fetchJob, onUnauthorized);

  // Fetched once the job is known, and again when its head moves; a status move leaves it be.
  const loaded = job !== null;
  const headSha = job?.headSha;
  const fetchDiff = useCallback(
    () => (loaded ? api.diff(id) : Promise.resolve(null)),
    [id, loaded, headSha],
  );
  const { data: diff, error: diffError } = useLoad<JobDiff | null>(fetchDiff, onUnauthorized);
  const files = useMemo<DiffFile[] | null>(
    () => (diff === null ? null : parseDiff(diff.diff)),
    [diff],
  );

  const [edits, setEdits] = useState<Edits | null>(null);
  const [selection, setSelection] = useState<Selection | null>(null);
  // A 409: the job is not what this page last saw. Shown until the person picks a way on.
  const [conflict, setConflict] = useState<string | null>(null);
  const [rebased, setRebased] = useState<Rebased | null>(null);
  const [busy, setBusy] = useState(false);
  const [confirmPost, setConfirmPost] = useState(false);
  // Edits an earlier page of this job left in the tab's storage, until restored or discarded.
  const [offer, setOffer] = useState<Stashed | null>(() => {
    const s = unstash(id);
    return s !== null && !sameReview(s.base, s.review) ? s : null;
  });

  const saved = useMemo(() => toLocal(job?.review ?? emptyReview), [job?.review]);
  const current = edits?.review ?? saved;

  // The edit actions are stable, so that the diff's files need not redraw when they are made;
  // they read the latest job and edits through refs.
  const baseRef = useRef({ version: 0, review: saved });
  baseRef.current = { version: job?.version ?? 0, review: saved };
  const editsRef = useRef(edits);
  editsRef.current = edits;

  const modify = useCallback<Modify>(
    (f) =>
      setEdits((e) => {
        if (e !== null) return { ...e, review: f(e.review, e.base) };
        const { version, review } = baseRef.current;
        return { jobId: id, version, base: review, review: f(review, review) };
      }),
    [id],
  );

  const actions = useMemo<CommentActions>(
    () => ({
      add: (c: InlineComment) => {
        // A key neither the edits nor their base has used: a key the base had is that comment.
        modify((r, b) => ({ ...r, comments: [...r.comments, { ...c, [KEY]: freshKeys(r, b)() }] }));
        setSelection(null);
      },
      update: (key: number, c: InlineComment) =>
        modify((r) => ({
          ...r,
          comments: r.comments.map((old) => (old[KEY] === key ? mergeComment(old, c) : old)),
        })),
      remove: (key: number) =>
        modify((r) => ({ ...r, comments: r.comments.filter((c) => c[KEY] !== key) })),
      cancelSelection: () => setSelection(null),
    }),
    [modify],
  );

  // Open comment forms holding text: unsaved too, though not in the edits yet.
  const openForms = useRef(new Set<string>());
  const [formsDirty, setFormsDirty] = useState(false);
  const reportForm = useCallback((formId: string, dirty: boolean) => {
    if (dirty) openForms.current.add(formId);
    else openForms.current.delete(formId);
    setFormsDirty(openForms.current.size > 0);
  }, []);

  const unresolved =
    rebased !== null && rebased.conflicts.some((c) => rebased.picks[conflictId(c)] === undefined);
  const dirty = edits !== null || formsDirty;

  // Every change is kept in the tab's storage, so that a 401, a reload or leaving loses nothing.
  // While conflicts are open, what is kept is the edits from before the move, which restoring
  // moves again: the conflicts come back rather than being settled for the person.
  useEffect(() => {
    if (edits === null) return;
    stash(unresolved && rebased !== null ? rebased.source : edits);
  }, [edits, rebased, unresolved]);

  const unsaved = useContext(UnsavedContext);
  useEffect(() => {
    unsaved.current = dirty;
    return () => {
      unsaved.current = false;
    };
  }, [unsaved, dirty]);

  useEffect(() => {
    if (!dirty) return;
    const warn = (e: BeforeUnloadEvent) => e.preventDefault();
    window.addEventListener("beforeunload", warn);
    return () => window.removeEventListener("beforeunload", warn);
  }, [dirty]);

  const blocker = useBlocker(
    ({ currentLocation, nextLocation }) =>
      dirty && currentLocation.pathname !== nextLocation.pathname,
  );
  useEffect(() => {
    if (blocker.state !== "blocked") return;
    if (
      window.confirm(
        "This review has unsaved edits. Leave anyway? They are kept in this tab and offered back when you open this job again.",
      )
    )
      blocker.proceed();
    else blocker.reset();
  }, [blocker]);

  const placement = useMemo(() => placeComments(files ?? [], current.comments), [files, current]);

  if (job === null)
    return error !== null ? <p className="error">{error}</p> : <p className="mute">Loading…</p>;

  const editable = canEdit(job.status) && job.reviewError === null && offer === null;

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

  /**
   * Move edits `e` onto job `j`. `announce`: say so even when nothing conflicts, because the
   * person did not ask for it to happen quietly (a reload after a 409, a restore).
   */
  const mergeOnto = (j: Job, e: Edits, announce: boolean) => {
    setJob(j);
    if (j.reviewError !== null) {
      setEdits(e);
      setError(
        "The job's review can no longer be read by this version, so your edits could not be moved onto it. They are kept here; Edit as JSON shows them.",
      );
      return;
    }
    const r = rebase(e.base, e.review, j.review ?? emptyReview);
    if (r.conflicts.length === 0 && sameReview(r.review, r.base)) {
      setEdits(null);
      setRebased(null);
      dropStash(id);
      return;
    }
    setEdits({ jobId: id, version: j.version, base: r.base, review: r.review });
    setRebased(
      announce || r.conflicts.length > 0
        ? { from: e.version, to: j.version, conflicts: r.conflicts, picks: {}, source: e }
        : null,
    );
  };

  const save = () => {
    const sent = edits;
    if (sent === null || unresolved) return;
    if (sent.jobId !== job.id) {
      setError("These edits were made to another job; they are not saved here.");
      return;
    }
    const review = toReview(sent.review);
    const problem = reviewProblem(review);
    if (problem !== null) {
      setError(problem);
      return;
    }
    setBusy(true);
    setError(null);
    api
      .putReview(job.id, sent.version, review)
      .then((j) => {
        const now = editsRef.current;
        if (now === null || now === sent) {
          setJob(j);
          setEdits(null);
          setRebased(null);
          dropStash(id);
        } else {
          // Edits made while the save was on its way: what was sent is saved now, and the
          // rest are changes to it.
          mergeOnto(j, { ...now, version: sent.version, base: sent.review }, false);
        }
      })
      .catch(fail)
      .finally(() => setBusy(false));
  };

  const discard = () => {
    setEdits(null);
    setRebased(null);
    dropStash(id);
    setError(null);
  };

  const reloadDiscarding = () => {
    discard();
    setConflict(null);
    reload();
  };

  const reloadMerging = () => {
    setBusy(true);
    api
      .job(id)
      .then((j) => {
        setConflict(null);
        const e = editsRef.current;
        if (e === null) setJob(j);
        else mergeOnto(j, e, true);
      })
      .catch(fail)
      .finally(() => setBusy(false));
  };

  const pick = (c: Conflict, which: Pick) => {
    setRebased((rb) =>
      rb === null ? rb : { ...rb, picks: { ...rb.picks, [conflictId(c)]: which } },
    );
    modify((r) => resolve(r, c, which));
  };

  const restore = () => {
    if (offer === null) return;
    setOffer(null);
    mergeOnto(job, offer, offer.version !== job.version);
  };

  const dropOffer = () => {
    dropStash(id);
    setOffer(null);
  };

  const moves = nextStatuses(job.status);
  const blockers = postBlockers(job, dirty, diff, diffError, placement);

  return (
    <FormsContext.Provider value={reportForm}>
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

      {offer !== null && (
        <div className="notice warn-notice" role="alert">
          <p>
            This tab holds unsaved edits to this review from earlier (made to version{" "}
            {offer.version}, kept {offer.savedAt}).
            {offer.version !== job.version &&
              ` The job is at version ${job.version} now; restoring moves them onto it, and asks where both changed the same thing.`}
          </p>
          <div className="actions">
            <button type="button" onClick={restore}>
              Restore them
            </button>
            <button type="button" className="ghost" onClick={dropOffer}>
              Discard them
            </button>
          </div>
        </div>
      )}
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
          {edits !== null ? (
            <>
              <p>
                Your edits are still here. Reload the job and move them onto it (where you and the
                other change touched the same thing, you choose), or drop them.
              </p>
              <div className="actions">
                <button type="button" onClick={reloadMerging} disabled={busy}>
                  Reload and keep my edits
                </button>
                <button type="button" className="ghost" onClick={reloadDiscarding}>
                  Reload, discard my edits
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
      {rebased !== null && edits !== null && <ConflictNotice rebased={rebased} onPick={pick} />}

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
              disabled={busy || blockers.length > 0 || confirmPost}
              aria-describedby={blockers.length > 0 ? "post-blockers" : undefined}
              onClick={() => setConfirmPost(true)}
            >
              Post to GitHub…
            </button>
          )}
          {dirty && moves.length > 0 && (
            <span className="mute small-text">Save or discard your edits first.</span>
          )}
        </div>
      )}
      {canPost(job.status) && blockers.length > 0 && (
        <ul id="post-blockers" className="mute small-text blockers">
          {blockers.map((b) => (
            <li key={b}>Not postable yet: {b}</li>
          ))}
        </ul>
      )}
      {confirmPost && canPost(job.status) && blockers.length === 0 && (
        <PostDialog
          job={job}
          busy={busy}
          onPost={() => run(api.post(job.id, job.version), () => setConfirmPost(false))}
          onClose={() => setConfirmPost(false)}
        />
      )}

      <h2>Review</h2>
      {job.reviewError !== null ? (
        <p className="error">The stored review cannot be read by this version: {job.reviewError}</p>
      ) : job.review === null && !editable && edits === null ? (
        <p className="mute">No review yet.</p>
      ) : (
        <Summary review={current} editable={editable} modify={modify} />
      )}

      {job.reviewError === null && (
        <DiffSection
          job={job}
          diff={diff}
          diffError={diffError}
          files={files}
          placement={placement}
          comments={current.comments}
          editable={editable}
          selection={selection}
          setSelection={setSelection}
          actions={actions}
        />
      )}

      {(editable || edits !== null) && (
        <RawEditor review={current} base={edits?.base ?? saved} modify={modify} />
      )}

      {dirty && (
        <div className="savebar" role="region" aria-label="Unsaved changes">
          <span>
            {edits !== null ? "Unsaved changes." : "A comment form holds text not yet added."}
            {edits !== null && formsDirty && " A comment form holds text not yet added."}
            {edits !== null &&
              (!editable
                ? ` A ${job.status} job's review is not edited; discard, or copy them from Edit as JSON first.`
                : unresolved
                  ? " Choose a side for each conflict above before saving."
                  : job.status !== "draft" &&
                    job.status !== "pending" &&
                    " Saving makes the job a draft again.")}
          </span>
          {edits !== null && (
            <span className="actions">
              <button type="button" onClick={save} disabled={busy || !editable || unresolved}>
                Save review
              </button>
              <button type="button" className="ghost" onClick={discard} disabled={busy}>
                Discard
              </button>
            </span>
          )}
        </div>
      )}
    </FormsContext.Provider>
  );
}

/** Why the review cannot be posted as it stands, if it cannot; empty when it can. */
export function postBlockers(
  job: Job,
  dirty: boolean,
  diff: JobDiff | null,
  diffError: string | null,
  placement: Placement,
): string[] {
  const out: string[] = [];
  if (dirty) out.push("save or discard the edits first, comment forms included.");
  if (diffError !== null || diff === null)
    out.push("the diff is not loaded, so where the comments land cannot be checked.");
  else if (job.headSha === null || diff.headSha !== job.headSha)
    out.push(
      `the diff is of ${diff.headSha.slice(0, 12)}, not of the job's head ${job.headSha?.slice(0, 12) ?? "(none)"}.`,
    );
  const n = placement.outside.length;
  if (diff !== null && n > 0)
    out.push(
      `${n} ${n === 1 ? "comment is" : "comments are"} outside the diff; GitHub refuses them.`,
    );
  const m = placement.split.size;
  if (m > 0)
    out.push(
      `${m} ${m === 1 ? "comment spans" : "comments span"} more than one hunk; GitHub refuses them.`,
    );
  return out;
}

/**
 * The last question before posting, as a modal dialog: the browser keeps focus inside it and
 * Escape closes it. Focus starts on Cancel, since posting cannot be taken back.
 */
function PostDialog({
  job,
  busy,
  onPost,
  onClose,
}: {
  job: Job;
  busy: boolean;
  onPost: () => void;
  onClose: () => void;
}) {
  const dialog = useRef<HTMLDialogElement>(null);
  const cancel = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    const d = dialog.current;
    if (d === null) return;
    if (!d.open) d.showModal();
    cancel.current?.focus();
    return () => d.close();
  }, []);
  return (
    <dialog
      ref={dialog}
      className="confirm"
      aria-labelledby="post-q"
      aria-modal="true"
      onCancel={(e) => {
        e.preventDefault();
        onClose();
      }}
    >
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
        <button ref={cancel} type="button" className="ghost" onClick={onClose}>
          Cancel
        </button>
        <button type="button" disabled={busy} onClick={onPost}>
          Post review
        </button>
      </div>
    </dialog>
  );
}

const fieldLabel: Record<string, string> = { decision: "The decision", body: "The summary" };

function show(v: unknown): string {
  if (v === undefined) return "(none)";
  if (typeof v === "string") return v === "" ? "(empty)" : v;
  return JSON.stringify(v, null, 2);
}

function showComment(c: LocalComment | null): string {
  if (c === null) return "(deleted)";
  return c.body + (c.suggestion === undefined ? "" : `\n\nSuggested change:\n${c.suggestion}`);
}

function conflictLabel(c: Conflict): string {
  if (c.kind === "field") return fieldLabel[c.name] ?? `The field "${c.name}"`;
  const any = c.mine ?? c.theirs;
  return any === null ? "A comment" : `The comment on ${any.file}, ${rangeLabel(any)}`;
}

/** What a move onto a newer version did, and a choice for each thing both sides changed. */
function ConflictNotice({
  rebased,
  onPick,
}: {
  rebased: Rebased;
  onPick: (c: Conflict, which: Pick) => void;
}) {
  const open = rebased.conflicts.filter((c) => rebased.picks[conflictId(c)] === undefined).length;
  return (
    <section className="notice warn-notice" aria-labelledby="rebase-h">
      <p id="rebase-h">
        Your edits were moved from version {rebased.from} onto version {rebased.to}, which someone
        or something else changed. They are not saved yet.
        {rebased.conflicts.length === 0
          ? " Nothing you changed was changed there too."
          : open > 0
            ? ` Both sides changed ${open === 1 ? "one thing" : `${open} things`}; choose which to keep.`
            : " Every conflict has a side; save when ready."}
      </p>
      {rebased.conflicts.map((c) => {
        const cid = conflictId(c);
        const [mine, theirs] =
          c.kind === "field"
            ? [show(c.mine), show(c.theirs)]
            : [showComment(c.mine), showComment(c.theirs)];
        return (
          <fieldset key={cid} className="conflict">
            <legend>{conflictLabel(c)}</legend>
            <label className="side">
              <input
                type="radio"
                name={cid}
                checked={rebased.picks[cid] === "mine"}
                onChange={() => onPick(c, "mine")}
              />
              <span>
                Keep mine
                <span className="value">{mine}</span>
              </span>
            </label>
            <label className="side">
              <input
                type="radio"
                name={cid}
                checked={rebased.picks[cid] === "theirs"}
                onChange={() => onPick(c, "theirs")}
              />
              <span>
                Keep theirs (version {rebased.to})<span className="value">{theirs}</span>
              </span>
            </label>
          </fieldset>
        );
      })}
    </section>
  );
}

function Summary({
  review,
  editable,
  modify,
}: {
  review: LocalReview;
  editable: boolean;
  modify: Modify;
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
  diff,
  diffError,
  files,
  placement,
  comments,
  editable,
  selection,
  setSelection,
  actions,
}: {
  job: Job;
  diff: JobDiff | null;
  diffError: string | null;
  files: DiffFile[] | null;
  placement: Placement;
  comments: LocalComment[];
  editable: boolean;
  selection: Selection | null;
  setSelection: (f: (s: Selection | null) => Selection | null) => void;
  actions: CommentActions;
}) {
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
      <h2 id="diff-h" tabIndex={-1}>
        Diff
      </h2>
      {diffError !== null ? (
        <p className="error">The diff could not be loaded: {diffError}</p>
      ) : files === null ? (
        <p className="mute">Loading the diff…</p>
      ) : (
        <>
          {diff !== null && job.headSha !== null && diff.headSha !== job.headSha && (
            <p className="notice warn-notice">
              This diff is of <span className="data">{diff.headSha.slice(0, 12)}</span>, not of the
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
          <h2 id="outside-h" tabIndex={-1}>
            {files === null ? "Comments" : "Outside the diff"}
          </h2>
          <p className="mute small-text">
            {files === null
              ? "Listed by place until the diff is shown."
              : "These comments name lines the diff does not show, or a file it does not touch. GitHub refuses such comments: move them onto lines of the diff, or delete them, before posting."}
          </p>
          {(files === null ? comments : placement.outside).map((c) => (
            <CommentCard
              key={c[KEY]}
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
  base,
  modify,
}: {
  review: LocalReview;
  base: LocalReview;
  modify: Modify;
}) {
  const [open, setOpen] = useState(false);
  const [text, setText] = useState("");
  const [problem, setProblem] = useState<string | null>(null);
  const [applied, setApplied] = useState(false);

  const apply = () => {
    // Keyed against the edits, so that a comment changed here is the same comment to an open
    // form and to a later merge, not a deleted one and a new one.
    const r = fromJson(text, review, base);
    if (typeof r === "string") {
      setProblem(r);
      return;
    }
    setProblem(null);
    setApplied(true);
    modify(() => r);
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
          setApplied(false);
        }
      }}
    >
      <summary>Edit as JSON</summary>
      <p className="mute small-text">
        The review with the edits so far, fields this page does not know included. Applying replaces
        the edits; Save review then sends them.
      </p>
      <textarea
        className="data"
        aria-label="The review as JSON"
        rows={18}
        spellCheck={false}
        value={text}
        onChange={(e) => {
          setText(e.target.value);
          setApplied(false);
        }}
      />
      {problem !== null && (
        <p className="error" role="alert">
          {problem}
        </p>
      )}
      {applied && (
        <p className="mute small-text" role="status">
          Applied.
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