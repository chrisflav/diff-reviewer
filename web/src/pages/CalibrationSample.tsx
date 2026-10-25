import { useCallback, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { api, UnauthorizedError } from "../api";
import { lines, scopeMeans } from "../calibration";
import { useLoad } from "../useLoad";
import { CalibrationCrumbs, repoPath, SplitTag } from "./Calibration";

export function CalibrationSamplePage({ onUnauthorized }: { onUnauthorized: () => void }) {
  const { owner = "", name = "", id = "" } = useParams();
  const fetch = useCallback(() => api.calibrationSample(owner, name, id), [owner, name, id]);
  const { data: s, error, setError } = useLoad(fetch, onUnauthorized);
  const [busy, setBusy] = useState(false);
  const navigate = useNavigate();

  const remove = () => {
    if (
      !window.confirm(
        "Delete this sample? It is no longer listed, run or counted, and importing again does not bring it back. The scores of the jobs that reviewed it are kept.",
      )
    )
      return;
    setBusy(true);
    api
      .deleteCalibrationSample(owner, name, id)
      .then(() => navigate(`${repoPath(owner, name)}/calibration#samples`))
      .catch((err: unknown) => {
        if (err instanceof UnauthorizedError) onUnauthorized();
        else setError(err instanceof Error ? err.message : String(err));
      })
      .finally(() => setBusy(false));
  };

  return (
    <>
      <CalibrationCrumbs owner={owner} name={name} here="Sample" />
      {error !== null && (
        <p className="error">
          {error}
          {error === "not found" &&
            ": there is no such sample, or it was deleted. A deleted sample is shown, marked, in the runs that used it."}
        </p>
      )}
      {s === null ? (
        error === null && <p className="mute">Loading…</p>
      ) : (
        <>
          <h1>
            #{s.prNumber} reviewed by <span className="data">{s.reviewer}</span>
          </h1>
          <p className="pr-title">{s.title}</p>
          <dl className="facts">
            <dt>Sample</dt>
            <dd className="data">{s.id}</dd>
            {s.split !== undefined && (
              <>
                <dt>Split</dt>
                <dd>
                  <SplitTag split={s.split} />{" "}
                  <span className="mute small-text">
                    {s.split === "eval"
                      ? "held out: what calibration measures by, never learned from"
                      : s.split === "pool"
                        ? "what the style examples and rubric proposals learn from; runs of it are never counted"
                        : "given one the first time it is read for a run"}
                  </span>
                </dd>
              </>
            )}
            <dt>State</dt>
            <dd className="data">{s.state}</dd>
            <dt>Scope</dt>
            <dd>
              <span className={`tag scope-${s.scope}`}>{s.scope}</span>{" "}
              <span className="mute small-text">{scopeMeans[s.scope] ?? ""}</span>
            </dd>
            <dt>Commit</dt>
            <dd className="data">{s.commitId}</dd>
            <dt>Base</dt>
            <dd className="data">{s.baseSha}</dd>
            <dt>Reviews</dt>
            <dd className="data">{s.reviewIds.join(", ")}</dd>
            <dt>Dropped</dt>
            <dd>
              {s.dropped.left} on the old side, {s.dropped.outdated} not anchored to the commit,{" "}
              {s.dropped.replies} {s.dropped.replies === 1 ? "reply" : "replies"}
            </dd>
            <dt>Reviewed</dt>
            <dd className="data">{s.submittedAt ?? "—"}</dd>
            <dt>Imported</dt>
            <dd className="data">{s.importedAt}</dd>
            <dt>Last merged</dt>
            <dd className="data">{s.updatedAt}</dd>
          </dl>
          <div className="actions">
            <button type="button" className="danger" disabled={busy} onClick={remove}>
              Delete sample
            </button>
          </div>
          <h2>The review</h2>
          {s.body.trim() === "" ? (
            <p className="mute">No body.</p>
          ) : (
            <p className="body review-body">{s.body}</p>
          )}
          <h2>Inline comments ({s.comments.length})</h2>
          {s.comments.length === 0 ? (
            <p className="mute">None.</p>
          ) : (
            <ol className="human-comments">
              {s.comments.map((c) => (
                <li key={c.id}>
                  <article className="comment side-human">
                    <header>
                      <span className="data">
                        {c.path}:{lines(c.start_line, c.line)}
                      </span>
                    </header>
                    <p className="body">{c.body}</p>
                  </article>
                </li>
              ))}
            </ol>
          )}
        </>
      )}
    </>
  );
}