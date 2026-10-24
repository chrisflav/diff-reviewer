import { useCallback, useEffect, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { api, nextStatuses, UnauthorizedError, type Job, type JobStatus, type Review } from "../api";
import { useLoad } from "../useLoad";

const actionLabel: Partial<Record<JobStatus, string>> = {
  approved: "Approve",
  rejected: "Reject",
  stale: "Mark stale",
  posted: "Mark posted",
  draft: "Back to draft",
};

const emptyReview: Review = { decision: "comment", body: "", comments: [] };

export function JobPage({ onUnauthorized }: { onUnauthorized: () => void }) {
  const { id = "" } = useParams();
  const fetchJob = useCallback(() => api.job(id), [id]);
  const { data: job, error, reload, setError } = useLoad<Job>(fetchJob, onUnauthorized);
  const [draft, setDraft] = useState("");
  const [editing, setEditing] = useState(false);

  useEffect(() => {
    if (job !== null && !editing) setDraft(JSON.stringify(job.review ?? emptyReview, null, 2));
  }, [job, editing]);

  const fail = (err: unknown) => {
    if (err instanceof UnauthorizedError) onUnauthorized();
    else setError(err instanceof Error ? err.message : String(err));
  };

  if (job === null) return error !== null ? <p className="error">{error}</p> : <p className="mute">Loading…</p>;

  const save = () => {
    let review: Review;
    try {
      review = JSON.parse(draft) as Review;
    } catch {
      setError("The review is not valid JSON.");
      return;
    }
    api
      .putReview(job.id, review)
      .then(() => {
        setEditing(false);
        reload();
      })
      .catch(fail);
  };

  const move = (to: JobStatus) => {
    api.setStatus(job.id, to).then(reload).catch(fail);
  };

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
      {error !== null && <p className="error">{error}</p>}

      <div className="actions">
        {nextStatuses(job.status).map((s) => (
          <button key={s} className={s === "approved" ? "" : "ghost"} onClick={() => move(s)}>
            {actionLabel[s] ?? s}
          </button>
        ))}
      </div>

      <h2>Review</h2>
      {job.review === null ? (
        <p className="mute">No review yet.</p>
      ) : (
        <ReviewView review={job.review} />
      )}

      {job.status !== "posted" && (
        <details open={editing} onToggle={(e) => setEditing(e.currentTarget.open)}>
          <summary>Edit the review</summary>
          <p className="mute">
            The review as JSON. Saving makes the job a draft again. A diff view with inline editing
            replaces this in the next milestone.
          </p>
          <textarea
            className="data"
            rows={18}
            spellCheck={false}
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
          />
          <button onClick={save}>Save</button>
        </details>
      )}
    </>
  );
}

const decisionLabel = {
  comment: "Comment",
  approve: "Approve",
  request_changes: "Request changes",
} as const;

function ReviewView({ review }: { review: Review }) {
  return (
    <section className="review">
      <p>
        <span className={`decision d-${review.decision}`}>{decisionLabel[review.decision]}</span>
      </p>
      {review.body !== "" && <p className="body">{review.body}</p>}
      {review.comments.length === 0 ? (
        <p className="mute">No inline comments.</p>
      ) : (
        <ol className="comments">
          {review.comments.map((c, i) => (
            <li key={i}>
              <div className="where data">
                {c.file}:{c.start_line}
                {c.end_line !== c.start_line ? `–${c.end_line}` : ""}
              </div>
              <p className="body">{c.body}</p>
              {c.suggestion !== undefined && <pre className="suggestion">{c.suggestion}</pre>}
            </li>
          ))}
        </ol>
      )}
    </section>
  );
}