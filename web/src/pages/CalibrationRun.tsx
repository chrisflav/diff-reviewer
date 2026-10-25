import { useCallback } from "react";
import { Link, useParams } from "react-router-dom";
import { api, type CalibrationRunResult } from "../api";
import { isScore, scopeMeans } from "../calibration";
import {
  AggregateBreakdown,
  AggregateFigures,
  Limits,
  PairView,
} from "../components/CalibrationParts";
import { Ratio } from "../components/Ratio";
import { useLoad } from "../useLoad";
import {
  CalibrationCrumbs,
  jobCounts,
  repoPath,
  StaleToggle,
  usePoll,
  useStale,
} from "./Calibration";

export function CalibrationRunPage({ onUnauthorized }: { onUnauthorized: () => void }) {
  const { owner = "", name = "", id = "" } = useParams();
  const [stale, setStale] = useStale();
  const fetch = useCallback(
    () => api.calibrationRun(owner, name, id, stale),
    [owner, name, id, stale],
  );
  const { data: run, error, reload } = useLoad(fetch, onUnauthorized);
  const live = run?.results?.some((r) => ["pending", "queued", "running"].includes(r.status));
  usePoll(reload, live ?? false);

  return (
    <>
      <CalibrationCrumbs owner={owner} name={name} here="Run" />
      <h1>
        Run <span className="data">{id}</span>
      </h1>
      {error !== null && <p className="error">{error}</p>}
      {run === null ? (
        error === null && <p className="mute">Loading…</p>
      ) : (
        <>
          <dl className="facts">
            <dt>Started</dt>
            <dd className="data">{run.createdAt}</dd>
            <dt>Samples</dt>
            <dd className="data">{run.samples}</dd>
            <dt>Jobs</dt>
            <dd>{jobCounts(run.jobs)}</dd>
          </dl>
          <Limits />
          <StaleToggle stale={stale} onChange={setStale} />
          <h2>Aggregate</h2>
          <p className="mute small-text">
            Of this run's scores, deleted samples left out
            {stale ? ", stale scores counted" : ", stale scores left out"}.
          </p>
          <AggregateFigures a={run.aggregate} />
          <AggregateBreakdown a={run.aggregate} />
          <h2>Per sample</h2>
          {(run.results ?? []).length === 0 ? (
            <p className="mute">No results.</p>
          ) : (
            <>
              <div className="table-scroll">
                <table>
                  <thead>
                    <tr>
                      <th scope="col">Sample</th>
                      <th scope="col">Job</th>
                      <th scope="col">Scope</th>
                      <th scope="col">Precision</th>
                      <th scope="col">Recall</th>
                      <th scope="col">Decision (agent / person)</th>
                    </tr>
                  </thead>
                  <tbody>
                    {(run.results ?? []).map((r) => (
                      <ResultRow key={r.jobId} owner={owner} name={name} r={r} />
                    ))}
                  </tbody>
                </table>
              </div>
              <h2>Comments, paired</h2>
              <p className="mute small-text">
                Each sample's comments by file: a pair side by side (the agent's left, the person's
                right), and what was left unpaired on either side. Paired means near each other, not
                saying the same.
              </p>
              {(run.results ?? []).map((r) => (
                <ResultPairs key={r.jobId} r={r} />
              ))}
            </>
          )}
        </>
      )}
    </>
  );
}

function Flags({ r }: { r: CalibrationRunResult }) {
  return (
    <>
      {r.sample?.deleted === true && (
        <span className="tag flag-deleted" title="Left out of every aggregate.">
          deleted
        </span>
      )}
      {r.scoreStale && (
        <span
          className="tag flag-stale"
          title="A review joined the sample after this score was made; the score is kept as it was."
        >
          stale
        </span>
      )}
    </>
  );
}

function ResultRow({ owner, name, r }: { owner: string; name: string; r: CalibrationRunResult }) {
  const s = r.sample;
  const score = r.score;
  const full = isScore(score) && score.scope === "full";
  return (
    <tr className={s?.deleted === true || r.scoreStale ? "dimmed" : undefined}>
      <td>
        {s === null ? (
          <span className="mute">gone</span>
        ) : s.deleted ? (
          <span>
            #{s.prNumber} <span className="data">{s.reviewer}</span>
          </span>
        ) : (
          <Link to={`${repoPath(owner, name)}/calibration/samples/${encodeURIComponent(s.id)}`}>
            #{s.prNumber} <span className="data">{s.reviewer}</span>
          </Link>
        )}{" "}
        <Flags r={r} />
      </td>
      <td>
        <Link to={`/jobs/${encodeURIComponent(r.jobId)}`}>
          <span className={`status s-${r.status}`}>{r.status}</span>
        </Link>
        {r.error !== null && <div className="error small-text body">{r.error}</div>}
      </td>
      <td>
        {s !== null && (
          <span className={`tag scope-${s.scope}`} title={scopeMeans[s.scope] ?? undefined}>
            {s.scope}
          </span>
        )}
      </td>
      {score === null ? (
        <td colSpan={3} className="mute">
          not scored yet
        </td>
      ) : !isScore(score) ? (
        <td colSpan={3} className="warn">
          unscorable: <span className="body">{"unscorable" in score ? score.unscorable : "?"}</span>
        </td>
      ) : (
        <>
          <td>
            {full ? (
              <Ratio num={score.matched} den={score.agentComments} value={score.precision} />
            ) : (
              <span className="mute small-text">decision only</span>
            )}
          </td>
          <td>
            {full ? (
              <Ratio num={score.matched} den={score.humanComments} value={score.recall} />
            ) : (
              <span className="mute small-text">decision only</span>
            )}
          </td>
          <td>
            <span className="data">{score.decision.agent}</span> /{" "}
            <span className="data">{score.decision.human}</span>{" "}
            {score.decision.agree === null ? (
              <span className="mute">not compared</span>
            ) : score.decision.agree ? (
              <span className="agree">agree</span>
            ) : (
              <span className="disagree">differ</span>
            )}
          </td>
        </>
      )}
    </tr>
  );
}

function ResultPairs({ r }: { r: CalibrationRunResult }) {
  const s = r.sample;
  const score = r.score;
  const title = s === null ? `Job ${r.jobId}` : `#${s.prNumber} by ${s.reviewer}: ${s.title}`;
  return (
    <details className="result-pairs">
      <summary>
        {title} <Flags r={r} />
      </summary>
      {!isScore(score) ? (
        <p className="mute">No score to show.</p>
      ) : (
        <>
          {score.scope !== "full" && (
            <p className="notice warn-notice small-text">
              A <code>{score.scope}</code> sample:{" "}
              {scopeMeans[score.scope] ?? "scored for its decision only."} The comments below are
              shown, and not counted.
            </p>
          )}
          <p className="mute small-text">
            {score.matched} paired of {score.agentComments} agent and {score.humanComments} person
            comments.
          </p>
          <PairView score={score} reviewer={s?.reviewer ?? null} />
        </>
      )}
    </details>
  );
}