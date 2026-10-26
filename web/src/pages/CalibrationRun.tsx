import { useCallback } from "react";
import { Link, useParams } from "react-router-dom";
import { api, type CalibrationRunResult } from "../api";
import { isScore, scopeMeans, scoreScope } from "../calibration";
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
  DerivedToggle,
  jobCounts,
  repoPath,
  SplitTag,
  StaleToggle,
  useDerived,
  usePoll,
  useStale,
} from "./Calibration";

export function CalibrationRunPage({ onUnauthorized }: { onUnauthorized: () => void }) {
  const { owner = "", name = "", id = "" } = useParams();
  const [stale, setStale] = useStale();
  const [derived, setDerived] = useDerived();
  const fetch = useCallback(
    () => api.calibrationRun(owner, name, id, stale, derived),
    [owner, name, id, stale, derived],
  );
  const { data: run, error, reload } = useLoad(fetch, onUnauthorized);
  const live = run?.results?.some((r) => ["pending", "queued", "running"].includes(r.status));
  usePoll(reload, live ?? false);
  // A run is of one split, which it records; one made before it did is of what its samples are of.
  const splits =
    run?.split !== undefined
      ? [run.split]
      : [
          ...new Set(
            (run?.results ?? []).flatMap((r) => (r.sample?.split ? [r.sample.split] : [])),
          ),
        ];
  const pool = splits.length === 1 && splits[0] === "pool";

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
            {splits.length > 0 && (
              <>
                <dt>Of</dt>
                <dd>
                  {splits.map((x) => (
                    <SplitTag key={x} split={x} />
                  ))}{" "}
                  samples
                </dd>
              </>
            )}
          </dl>
          {pool && (
            <p className="notice warn-notice" role="status">
              <strong>A run of the pool: never counted.</strong> Its scores are in no aggregate,
              summary or chart; they are evidence for rubric proposals, which learn from the pool
              and never from what calibration measures by.
            </p>
          )}
          <Limits />
          <StaleToggle stale={stale} onChange={setStale} />
          <DerivedToggle derived={derived} onChange={setDerived} />
          <h2>Aggregate</h2>
          <p className="mute small-text">
            Of this run's <code>eval</code> scores, deleted samples left out
            {stale ? ", stale scores counted" : ", stale scores left out"}
            {derived ? ", derived scores counted" : ", derived scores left out"}.
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
      {r.scoreDerived === true && (
        <span
          className="tag flag-derived"
          title="The rubric or style notes this score was made under learned from this pull request: left out of the aggregate unless asked."
        >
          derived
        </span>
      )}
      {r.sample?.split === "pool" && <SplitTag split="pool" />}
    </>
  );
}

function ScopeTag({ scope }: { scope: string | null }) {
  if (scope === null) return null;
  return (
    <span className={`tag scope-${scope}`} title={scopeMeans[scope] ?? undefined}>
      {scope}
    </span>
  );
}

function ResultRow({ owner, name, r }: { owner: string; name: string; r: CalibrationRunResult }) {
  const s = r.sample;
  const score = r.score;
  const full = isScore(score) && scoreScope(score) === "full";
  // The scope the score was made with, and the sample's now when a later import changed it.
  const scored = isScore(score) ? scoreScope(score) : null;
  const now = s?.scope ?? null;
  return (
    <tr
      className={
        s?.deleted === true || r.scoreStale || r.scoreDerived === true ? "dimmed" : undefined
      }
    >
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
        <ScopeTag scope={scored ?? now} />
        {scored !== null && now !== null && now !== scored && (
          <div className="small-text mute">
            scored as {scored}; the sample is <ScopeTag scope={now} /> now
          </div>
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
          {scoreScope(score) !== "full" && (
            <p className="notice warn-notice small-text">
              Scored as a <code>{scoreScope(score)}</code> sample:{" "}
              {scopeMeans[scoreScope(score)] ?? "scored for its decision only."} The comments below
              are shown, and not counted.
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