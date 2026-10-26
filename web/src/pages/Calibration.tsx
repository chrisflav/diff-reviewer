import { useCallback, useEffect, useState, type FormEvent } from "react";
import { Link, useParams, useSearchParams } from "react-router-dom";
import {
  api,
  ApiError,
  scoreQuery,
  UnauthorizedError,
  type CalibrationImport,
  type CalibrationRun,
  type CalibrationSample,
  type Page,
} from "../api";
import { importLive, importState, importStats, MAX_RUN_SAMPLES, scopeMeans } from "../calibration";
import { AggregateBreakdown, AggregateFigures, Limits } from "../components/CalibrationParts";
import { Ratio } from "../components/Ratio";
import { RunChart } from "../components/RunChart";
import { useLoad } from "../useLoad";

/** Where a repository's pages are. */
export function repoPath(owner: string, name: string): string {
  return `/repos/${encodeURIComponent(owner)}/${encodeURIComponent(name)}`;
}

/** Reload every few seconds while `active`: an import or a run going on. */
export function usePoll(reload: () => void, active: boolean, ms = 5000) {
  useEffect(() => {
    if (!active) return;
    const t = window.setInterval(reload, ms);
    return () => window.clearInterval(t);
  }, [reload, active, ms]);
}

/** Whether stale scores are counted: `?stale=include` on the page, as on the API. */
export function useStale(): [boolean, (on: boolean) => void] {
  const [params, setParams] = useSearchParams();
  const stale = params.get("stale") === "include";
  const set = (on: boolean) =>
    setParams(
      (p) => {
        const n = new URLSearchParams(p);
        if (on) n.set("stale", "include");
        else n.delete("stale");
        return n;
      },
      { replace: true },
    );
  return [stale, set];
}

/** Whether derived scores are counted: `?derived=include` on the page, as on the API. */
export function useDerived(): [boolean, (on: boolean) => void] {
  const [params, setParams] = useSearchParams();
  const derived = params.get("derived") === "include";
  const set = (on: boolean) =>
    setParams(
      (p) => {
        const n = new URLSearchParams(p);
        if (on) n.set("derived", "include");
        else n.delete("derived");
        return n;
      },
      { replace: true },
    );
  return [derived, set];
}

/**
 * Whether only the scores of jobs checked out isolated at their commit are counted:
 * `?unisolated=exclude` on the page, as on the API.
 */
export function useIsolatedOnly(): [boolean, (on: boolean) => void] {
  const [params, setParams] = useSearchParams();
  const only = params.get("unisolated") === "exclude";
  const set = (on: boolean) =>
    setParams(
      (p) => {
        const n = new URLSearchParams(p);
        if (on) n.set("unisolated", "exclude");
        else n.delete("unisolated");
        return n;
      },
      { replace: true },
    );
  return [only, set];
}

export function IsolatedToggle({
  only,
  onChange,
}: {
  only: boolean;
  onChange: (on: boolean) => void;
}) {
  return (
    <label className="check">
      <input type="checkbox" checked={only} onChange={(e) => onChange(e.target.checked)} />
      Leave out scores of jobs not checked out isolated (run on the default branch, which may hold
      the change as merged)
    </label>
  );
}

export function DerivedToggle({
  derived,
  onChange,
}: {
  derived: boolean;
  onChange: (on: boolean) => void;
}) {
  return (
    <label className="check">
      <input type="checkbox" checked={derived} onChange={(e) => onChange(e.target.checked)} />
      Count derived scores too (scores of pull requests the rubric or style notes they were made
      under learned from)
    </label>
  );
}

/** `eval` or `pool`, as a tag: what a sample is for. */
export function SplitTag({ split }: { split: string | null | undefined }) {
  if (split === undefined) return null;
  if (split === null)
    return (
      <span className="tag" title="Not split yet: it is given one the first time it is read.">
        unsplit
      </span>
    );
  return (
    <span
      className={`tag split-${split}`}
      title={
        split === "eval"
          ? "Held out: what calibration measures by, never learned from."
          : split === "pool"
            ? "What the style examples and rubric proposals learn from; never counted."
            : undefined
      }
    >
      {split}
    </span>
  );
}

export function StaleToggle({
  stale,
  onChange,
}: {
  stale: boolean;
  onChange: (on: boolean) => void;
}) {
  return (
    <label className="check">
      <input type="checkbox" checked={stale} onChange={(e) => onChange(e.target.checked)} />
      Count stale scores too (scores of samples a later review has joined)
    </label>
  );
}

export function CalibrationCrumbs({
  owner,
  name,
  here,
}: {
  owner: string;
  name: string;
  here?: string;
}) {
  return (
    <p className="crumbs">
      <Link to="/repos">Repositories</Link> /{" "}
      <Link to={repoPath(owner, name)}>
        {owner}/{name}
      </Link>
      {" / "}
      {here === undefined ? (
        "Calibration"
      ) : (
        <>
          <Link to={`${repoPath(owner, name)}/calibration`}>Calibration</Link> / {here}
        </>
      )}
    </p>
  );
}

export function CalibrationPage({ onUnauthorized }: { onUnauthorized: () => void }) {
  const { owner = "", name = "" } = useParams();
  return (
    <CalibrationView
      key={`${owner}/${name}`}
      owner={owner}
      name={name}
      onUnauthorized={onUnauthorized}
    />
  );
}

function CalibrationView({
  owner,
  name,
  onUnauthorized,
}: {
  owner: string;
  name: string;
  onUnauthorized: () => void;
}) {
  const [stale, setStale] = useStale();
  const [derived, setDerived] = useDerived();
  const [isolatedOnly, setIsolatedOnly] = useIsolatedOnly();
  // Bumped by anything that changes what the sections show: a new run, a deleted sample.
  const [nonce, setNonce] = useState(0);
  const changed = () => setNonce((n) => n + 1);
  const [selected, setSelected] = useState<string[]>([]);

  return (
    <>
      <CalibrationCrumbs owner={owner} name={name} />
      <h1>
        Calibration of{" "}
        <span className="data">
          {owner}/{name}
        </span>
      </h1>
      <p className="mute small-text">
        How close are the agent's reviews to those of the people this repository trusts? The agent
        reviews past commits a trusted reviewer has reviewed, without being shown that review, and
        the two are compared. Calibration jobs are never posted. Trusted reviewers are set in the{" "}
        <Link to={repoPath(owner, name)}>repository's settings</Link>.
      </p>
      <nav className="toc" aria-label="Sections">
        <a href="#summary">Summary</a>
        <a href="#runs">Runs</a>
        <a href="#samples">Samples</a>
        <a href="#imports">Imports</a>
      </nav>
      <Limits />
      <StaleToggle stale={stale} onChange={setStale} />
      <DerivedToggle derived={derived} onChange={setDerived} />
      <IsolatedToggle only={isolatedOnly} onChange={setIsolatedOnly} />

      <Summary
        owner={owner}
        name={name}
        stale={stale}
        derived={derived}
        isolatedOnly={isolatedOnly}
        nonce={nonce}
        onUnauthorized={onUnauthorized}
      />
      <Runs
        owner={owner}
        name={name}
        stale={stale}
        derived={derived}
        isolatedOnly={isolatedOnly}
        nonce={nonce}
        selected={selected}
        onStarted={() => {
          setSelected([]);
          changed();
        }}
        onUnauthorized={onUnauthorized}
      />
      <Samples
        owner={owner}
        name={name}
        nonce={nonce}
        selected={selected}
        setSelected={setSelected}
        onUnauthorized={onUnauthorized}
      />
      <Imports owner={owner} name={name} onImported={changed} onUnauthorized={onUnauthorized} />
    </>
  );
}

function Summary({
  owner,
  name,
  stale,
  derived,
  isolatedOnly,
  nonce,
  onUnauthorized,
}: {
  owner: string;
  name: string;
  stale: boolean;
  derived: boolean;
  isolatedOnly: boolean;
  nonce: number;
  onUnauthorized: () => void;
}) {
  const fetch = useCallback(
    () => api.calibrationSummary(owner, name, stale, derived, isolatedOnly),
    [owner, name, stale, derived, isolatedOnly, nonce],
  );
  const { data: s, error } = useLoad(fetch, onUnauthorized);
  return (
    <section aria-labelledby="summary">
      <h2 id="summary">Summary</h2>
      {error !== null && <p className="error">{error}</p>}
      {s === null ? (
        error === null && <p className="mute">Loading…</p>
      ) : (
        <>
          <p className="mute small-text">
            Over {s.runs} {s.runs === 1 ? "run" : "runs"} and {s.samples}{" "}
            {s.samples === 1 ? "sample" : "samples"}, deleted samples left out
            {s.split !== undefined && (
              <>
                ; of <code>{s.split}</code> samples only, never the pool
              </>
            )}
            .
          </p>
          <AggregateFigures a={s.overall} />
          <AggregateBreakdown a={s.overall} />
          {s.byRubricVersion.length > 0 && (
            <>
              <h3>By rubric version</h3>
              <p className="mute small-text">
                The rubric version each job was reviewed against, newest first: whether a rubric
                change moved the numbers. Stale scores are {stale ? "counted" : "left out"}, derived
                ones {derived ? "counted" : "left out"}.
              </p>
              <div className="table-scroll">
                <table>
                  <thead>
                    <tr>
                      <th scope="col">Rubric</th>
                      <th scope="col">Scored</th>
                      <th scope="col">Precision</th>
                      <th scope="col">Recall</th>
                      <th scope="col">Decision agreement</th>
                    </tr>
                  </thead>
                  <tbody>
                    {s.byRubricVersion.map(({ rubricVersion: v, aggregate: a }) => (
                      <tr key={String(v)}>
                        <th scope="row">
                          {v === null ? (
                            <span className="mute">unrecorded</span>
                          ) : v === 0 ? (
                            <span className="mute">none</span>
                          ) : (
                            <Link to={`${repoPath(owner, name)}/rubric?version=${v}`}>
                              version {v}
                            </Link>
                          )}
                        </th>
                        <td className="data">
                          {a.scored} ({a.commentsScored} full)
                        </td>
                        <td>
                          <Ratio num={a.matched} den={a.agentComments} value={a.precision} />
                        </td>
                        <td>
                          <Ratio num={a.matched} den={a.humanComments} value={a.recall} />
                        </td>
                        <td>
                          <Ratio
                            num={a.decisions.agreed}
                            den={a.decisions.compared}
                            value={a.decisions.agreement}
                          />
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
              {s.byRubricVersion.map(({ rubricVersion: v, aggregate: a }) => (
                <details key={String(v)} className="by-version">
                  <summary>
                    Rubric {v === null ? "unrecorded" : v === 0 ? "none" : `version ${v}`}: by
                    category, severity and decision
                  </summary>
                  <AggregateFigures a={a} />
                  <AggregateBreakdown a={a} />
                </details>
              ))}
            </>
          )}
        </>
      )}
    </section>
  );
}

/** The live statuses of a calibration job: a run with any of them is still going on. */
const liveStatuses = ["pending", "queued", "running"];

function runLive(r: CalibrationRun): boolean {
  return liveStatuses.some((s) => (r.jobs[s] ?? 0) > 0);
}

/** A run's jobs by status, in words. */
export function jobCounts(jobs: Record<string, number>): string {
  const parts = Object.entries(jobs)
    .filter(([, n]) => n > 0)
    .map(([s, n]) => `${n} ${s}`);
  return parts.length === 0 ? "no jobs" : parts.join(", ");
}

function Runs({
  owner,
  name,
  stale,
  derived,
  isolatedOnly,
  nonce,
  selected,
  onStarted,
  onUnauthorized,
}: {
  owner: string;
  name: string;
  stale: boolean;
  derived: boolean;
  isolatedOnly: boolean;
  nonce: number;
  selected: string[];
  onStarted: () => void;
  onUnauthorized: () => void;
}) {
  const [offset, setOffset] = useState(0);
  const fetch = useCallback(
    () => api.calibrationRuns(owner, name, 50, offset, stale, derived, isolatedOnly),
    [owner, name, offset, stale, derived, isolatedOnly, nonce],
  );
  const { data, error, reload } = useLoad(fetch, onUnauthorized);
  usePoll(reload, data?.items.some(runLive) ?? false);
  const [count, setCount] = useState("5");
  const [busy, setBusy] = useState(false);
  const [startError, setStartError] = useState<string | null>(null);
  const [started, setStarted] = useState<CalibrationRun | null>(null);
  // What a run is of: `eval` unless asked, since only eval runs are measured by.
  const [split, setSplit] = useState<"eval" | "pool">("eval");

  const start = (which: { samples: string[] } | { count: number }) => {
    setBusy(true);
    setStartError(null);
    setStarted(null);
    api
      .createCalibrationRun(owner, name, { ...which, split })
      .then((r) => {
        setStarted(r);
        setOffset(0);
        onStarted();
      })
      .catch((err: unknown) => {
        if (err instanceof UnauthorizedError) return onUnauthorized();
        if (err instanceof ApiError && err.status === 429)
          setStartError(
            `Past the repository's daily cap of calibration jobs, so no run was started: ${err.message}`,
          );
        else if (err instanceof ApiError && err.status === 409)
          setStartError(`Refused, nothing was started: ${err.message}`);
        else setStartError(err instanceof Error ? err.message : String(err));
      })
      .finally(() => setBusy(false));
  };

  const n = Number(count);
  const countOk = Number.isInteger(n) && n >= 1 && n <= MAX_RUN_SAMPLES;
  const submit = (e: FormEvent) => {
    e.preventDefault();
    if (countOk) start({ count: n });
  };

  return (
    <section aria-labelledby="runs">
      <h2 id="runs">Runs</h2>
      <p className="mute small-text">
        A run makes one calibration job per sample, at most {MAX_RUN_SAMPLES}; each is charged to
        the repository's daily cap of calibration jobs. A sample a live job is reviewing already
        cannot be run again until it ends.
      </p>
      <fieldset className="split-pick">
        <legend>Of which samples</legend>
        <label className="check">
          <input
            type="radio"
            name="run-split"
            checked={split === "eval"}
            onChange={() => setSplit("eval")}
          />
          <code>eval</code>, held out: what calibration measures by
        </label>
        <label className="check">
          <input
            type="radio"
            name="run-split"
            checked={split === "pool"}
            onChange={() => setSplit("pool")}
          />
          <code>pool</code>: evidence for rubric proposals
        </label>
      </fieldset>
      {split === "pool" && (
        <p className="notice warn-notice small-text" role="status">
          A pool run is never counted: its scores are in no aggregate, summary or chart. It gives
          rubric proposals something to learn from; what the agent learns from is never what it is
          measured by.
        </p>
      )}
      <form className="inline" onSubmit={submit}>
        <label>
          {split === "pool" ? "Pool samples" : "Eval samples"} run least so far{" "}
          <input
            type="number"
            min={1}
            max={MAX_RUN_SAMPLES}
            inputMode="numeric"
            className="narrow"
            value={count}
            onChange={(e) => setCount(e.target.value)}
            aria-describedby="run-count-help"
          />
        </label>
        <button type="submit" disabled={busy || !countOk}>
          Run
        </button>
        <button
          type="button"
          disabled={busy || selected.length === 0}
          onClick={() => start({ samples: selected })}
        >
          Run the {selected.length === 0 ? "" : `${selected.length} `}selected{" "}
          {selected.length === 1 ? "sample" : "samples"} as {split}
        </button>
      </form>
      <p id="run-count-help" className="mute small-text">
        {countOk
          ? `Pick samples below to run those instead; every one must be of the ${split} split.`
          : `A whole number from 1 to ${MAX_RUN_SAMPLES}.`}
      </p>
      {startError !== null && (
        <p className="error" role="alert">
          {startError}
        </p>
      )}
      {started !== null && (
        <p className="notice" role="status">
          Started{" "}
          <Link to={`${repoPath(owner, name)}/calibration/runs/${encodeURIComponent(started.id)}`}>
            a run
          </Link>{" "}
          of {started.samples} {started.samples === 1 ? "sample" : "samples"}
          {split === "pool" ? " of the pool, never counted" : ""}.
        </p>
      )}
      {error !== null && <p className="error">{error}</p>}
      {data === null ? (
        error === null && <p className="mute">Loading…</p>
      ) : data.items.length === 0 && offset === 0 ? (
        <p className="mute">No runs yet.</p>
      ) : (
        <>
          {data.items.filter((r) => r.split !== "pool").length > 1 && (
            <RunChart runs={data.items} stale={stale} />
          )}
          <p className="mute small-text">
            Each run's figures are of its own <code>eval</code> scores, deleted samples left out;
            stale scores are {stale ? "counted" : "left out"}, derived ones{" "}
            {derived ? "counted" : "left out"}. A run of the pool shows no figures: it is never
            counted.
          </p>
          <div className="table-scroll">
            <table>
              <thead>
                <tr>
                  <th scope="col">Started</th>
                  <th scope="col">Samples</th>
                  <th scope="col">Jobs</th>
                  <th scope="col">Precision</th>
                  <th scope="col">Recall</th>
                  <th scope="col">Decision agreement</th>
                </tr>
              </thead>
              <tbody>
                {data.items.map((r) => (
                  <tr key={r.id}>
                    <td>
                      <Link
                        to={`${repoPath(owner, name)}/calibration/runs/${encodeURIComponent(r.id)}${scoreQuery(stale, derived, "?", isolatedOnly)}`}
                        className="data"
                      >
                        {r.createdAt}
                      </Link>{" "}
                      {r.split === "pool" && <SplitTag split="pool" />}
                    </td>
                    <td className="data">{r.samples}</td>
                    <td className="small-text">{jobCounts(r.jobs)}</td>
                    <td>
                      <Ratio
                        num={r.aggregate.matched}
                        den={r.aggregate.agentComments}
                        value={r.aggregate.precision}
                      />
                    </td>
                    <td>
                      <Ratio
                        num={r.aggregate.matched}
                        den={r.aggregate.humanComments}
                        value={r.aggregate.recall}
                      />
                    </td>
                    <td>
                      <Ratio
                        num={r.aggregate.decisions.agreed}
                        den={r.aggregate.decisions.compared}
                        value={r.aggregate.decisions.agreement}
                      />
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <Pager page={data} offset={offset} size={50} setOffset={setOffset} what="runs" />
        </>
      )}
    </section>
  );
}

export function Pager<T>({
  page,
  offset,
  size,
  setOffset,
  what,
}: {
  page: Page<T>;
  offset: number;
  size: number;
  setOffset: (o: number) => void;
  what: string;
}) {
  if (offset === 0 && page.nextOffset === null) return null;
  return (
    <div className="actions pager">
      <button
        type="button"
        className="ghost"
        disabled={offset === 0}
        onClick={() => setOffset(Math.max(0, offset - size))}
      >
        Newer {what}
      </button>
      <span className="mute small-text">
        {offset + 1}–{offset + page.items.length}
      </span>
      <button
        type="button"
        className="ghost"
        disabled={page.nextOffset === null}
        onClick={() => page.nextOffset !== null && setOffset(page.nextOffset)}
      >
        Older {what}
      </button>
    </div>
  );
}

const SAMPLE_PAGE = 25;

function Samples({
  owner,
  name,
  nonce,
  selected,
  setSelected,
  onUnauthorized,
}: {
  owner: string;
  name: string;
  nonce: number;
  selected: string[];
  setSelected: (f: (s: string[]) => string[]) => void;
  onUnauthorized: () => void;
}) {
  const [offset, setOffset] = useState(0);
  const fetch = useCallback(
    () => api.calibrationSamples(owner, name, SAMPLE_PAGE, offset),
    [owner, name, offset, nonce],
  );
  const { data, error } = useLoad(fetch, onUnauthorized);
  const full = selected.length >= MAX_RUN_SAMPLES;
  const toggle = (id: string, on: boolean) =>
    setSelected((s) =>
      on
        ? s.includes(id) || s.length >= MAX_RUN_SAMPLES
          ? s
          : [...s, id]
        : s.filter((x) => x !== id),
    );

  return (
    <section aria-labelledby="samples">
      <h2 id="samples">Samples</h2>
      <p className="mute small-text">
        What one trusted reviewer said of one commit, every review of theirs of it merged; most
        recently reviewed first. Deleted samples are not listed: they are shown, marked, in the runs
        that used them. Pick up to {MAX_RUN_SAMPLES} to run. Each is held out as <code>eval</code>{" "}
        (what runs measure by) or in the <code>pool</code> (what examples and proposals learn from),
        by its pull request, once and for good.
      </p>
      <dl className="scopes small-text">
        {Object.entries(scopeMeans).map(([k, v]) => (
          <div key={k}>
            <dt className="data">{k}</dt>
            <dd>{v}</dd>
          </div>
        ))}
      </dl>
      {error !== null && <p className="error">{error}</p>}
      {selected.length > 0 && (
        <p className="mute small-text" role="status">
          {selected.length} selected{full && `, the most a run takes`}.{" "}
          <button type="button" className="ghost small" onClick={() => setSelected(() => [])}>
            Clear
          </button>
        </p>
      )}
      {data === null ? (
        error === null && <p className="mute">Loading…</p>
      ) : data.items.length === 0 && offset === 0 ? (
        <p className="mute">No samples yet: import the trusted reviewers' past reviews below.</p>
      ) : (
        <>
          <div className="table-scroll">
            <table>
              <thead>
                <tr>
                  <th scope="col">
                    <span className="sr-only">Run it</span>
                  </th>
                  <th scope="col">Pull request</th>
                  <th scope="col">Reviewer</th>
                  <th scope="col">Commit</th>
                  <th scope="col">State</th>
                  <th scope="col">Split</th>
                  <th scope="col">Scope</th>
                  <th scope="col">Comments</th>
                  <th scope="col">Reviewed</th>
                </tr>
              </thead>
              <tbody>
                {data.items.map((s) => (
                  <SampleRow
                    key={s.id}
                    owner={owner}
                    name={name}
                    s={s}
                    checked={selected.includes(s.id)}
                    disabled={full && !selected.includes(s.id)}
                    onToggle={(on) => toggle(s.id, on)}
                  />
                ))}
              </tbody>
            </table>
          </div>
          <Pager
            page={data}
            offset={offset}
            size={SAMPLE_PAGE}
            setOffset={setOffset}
            what="samples"
          />
        </>
      )}
    </section>
  );
}

function SampleRow({
  owner,
  name,
  s,
  checked,
  disabled,
  onToggle,
}: {
  owner: string;
  name: string;
  s: CalibrationSample;
  checked: boolean;
  disabled: boolean;
  onToggle: (on: boolean) => void;
}) {
  const deleted = (s as { deleted?: unknown }).deleted === true;
  return (
    <tr>
      <td>
        <input
          type="checkbox"
          checked={checked}
          disabled={disabled || deleted}
          onChange={(e) => onToggle(e.target.checked)}
          aria-label={`Run the sample of #${s.prNumber} by ${s.reviewer}`}
        />
      </td>
      <td>
        <Link to={`${repoPath(owner, name)}/calibration/samples/${encodeURIComponent(s.id)}`}>
          #{s.prNumber}
        </Link>{" "}
        <span className="mute">{s.title}</span>
        {deleted && <span className="tag flag-deleted">deleted</span>}
      </td>
      <td className="data">{s.reviewer}</td>
      <td className="data">{s.commitId.slice(0, 10)}</td>
      <td className="data">{s.state}</td>
      <td>
        <SplitTag split={s.split} />
      </td>
      <td>
        <span className={`tag scope-${s.scope}`} title={scopeMeans[s.scope] ?? undefined}>
          {s.scope}
        </span>
      </td>
      <td className="data">
        {s.comments.length}
        {s.dropped.left + s.dropped.outdated > 0 && (
          <span className="mute"> (+{s.dropped.left + s.dropped.outdated} dropped)</span>
        )}
      </td>
      <td className="data mute">{s.submittedAt ?? "—"}</td>
    </tr>
  );
}

function Imports({
  owner,
  name,
  onImported,
  onUnauthorized,
}: {
  owner: string;
  name: string;
  onImported: () => void;
  onUnauthorized: () => void;
}) {
  const fetch = useCallback(() => api.calibrationImports(owner, name, 10, 0), [owner, name]);
  const { data, error, reload } = useLoad(fetch, onUnauthorized);
  const live = data?.items.some(importLive) ?? false;
  usePoll(reload, live);
  // When an import ends, the samples it made are listed.
  const [wasLive, setWasLive] = useState(false);
  useEffect(() => {
    if (wasLive && !live) onImported();
    setWasLive(live);
  }, [live]);

  const [limit, setLimit] = useState("50");
  const [busy, setBusy] = useState(false);
  const [actError, setActError] = useState<string | null>(null);
  const n = Number(limit);
  const limitOk = Number.isInteger(n) && n >= 1 && n <= 200;

  const fail = (err: unknown) => {
    if (err instanceof UnauthorizedError) return onUnauthorized();
    setActError(err instanceof Error ? err.message : String(err));
    reload();
  };

  const start = (e: FormEvent) => {
    e.preventDefault();
    if (!limitOk) return;
    setBusy(true);
    setActError(null);
    api
      .importCalibration(owner, name, n)
      .then(reload)
      .catch(fail)
      .finally(() => setBusy(false));
  };

  const cancel = (i: CalibrationImport) => {
    if (!window.confirm("Cancel this import? What it has stored so far is kept.")) return;
    setBusy(true);
    setActError(null);
    api
      .cancelCalibrationImport(owner, name, i.id)
      .then(() => {
        reload();
        onImported();
      })
      .catch(fail)
      .finally(() => setBusy(false));
  };

  const [latest, ...older] = data?.items ?? [];

  return (
    <section aria-labelledby="imports">
      <h2 id="imports">Imports</h2>
      <p className="mute small-text">
        An import reads the trusted reviewers' reviews of the most recently updated closed pull
        requests, 25 a pass. Every review is looked at once: importing again adds only reviews no
        import has seen. GitHub's requests are shared with discovery and posting, so an import
        pauses when few are left, and goes on by itself after GitHub's limit resets.
      </p>
      <form className="inline" onSubmit={start}>
        <label>
          Closed pull requests to read{" "}
          <input
            type="number"
            min={1}
            max={200}
            inputMode="numeric"
            className="narrow"
            value={limit}
            onChange={(e) => setLimit(e.target.value)}
          />
        </label>
        <button type="submit" disabled={busy || !limitOk || live}>
          Import
        </button>
        {live && <span className="mute small-text">An import is under way.</span>}
        {!limitOk && <span className="warn small-text">A whole number from 1 to 200.</span>}
      </form>
      {actError !== null && (
        <p className="error" role="alert">
          {actError}
        </p>
      )}
      {error !== null && <p className="error">{error}</p>}
      {data === null ? (
        error === null && <p className="mute">Loading…</p>
      ) : latest === undefined ? (
        <p className="mute">No imports yet.</p>
      ) : (
        <>
          <ImportView i={latest} busy={busy} onCancel={() => cancel(latest)} />
          {older.length > 0 && (
            <details>
              <summary>Earlier imports</summary>
              {older.map((i) => (
                <ImportView key={i.id} i={i} busy={busy} onCancel={() => cancel(i)} />
              ))}
            </details>
          )}
        </>
      )}
    </section>
  );
}

function ImportView({
  i,
  busy,
  onCancel,
}: {
  i: CalibrationImport;
  busy: boolean;
  onCancel: () => void;
}) {
  const st = importState(i);
  const total = i.pullsListed;
  return (
    <article className="import">
      <header>
        <span className={`status s-${i.status}`}>{i.status}</span>{" "}
        <span className="data mute">{i.requestedAt}</span>{" "}
        <span className="mute small-text">(up to {i.limit} pull requests)</span>
      </header>
      <p>
        {total === null ? (
          "Listing the closed pull requests…"
        ) : (
          <>
            <progress
              max={Math.max(total, 1)}
              value={i.pullsRead}
              aria-label="Pull requests read"
            />{" "}
            {i.pullsRead} of {total} pull requests read
          </>
        )}
        {i.failures > 0 && (
          <span className="warn small-text">
            {" "}
            The next one has failed {i.failures} {i.failures === 1 ? "time" : "times"}; at 3 it is
            skipped.
          </span>
        )}
      </p>
      {st.kind === "paused" && (
        <p className="notice warn-notice" role="status">
          Paused
          {st.until !== null && (
            <>
              {" "}
              until <span className="data">{st.until}</span>
            </>
          )}
          , when GitHub's rate limit resets: the requests left are kept for discovery and posting.
          It goes on by itself. <span className="body mute small-text">{st.why}</span>
        </p>
      )}
      {st.kind === "rateLimited" && (
        <p className="notice warn-notice" role="status">
          Rate-limited by GitHub; it goes on by itself once the limit resets.{" "}
          <span className="body mute small-text">{st.why}</span>
        </p>
      )}
      {st.kind === "retrying" && (
        <p className="notice warn-notice" role="status">
          The last pass stopped short: <span className="body">{st.why}</span>
        </p>
      )}
      {st.kind === "ended" && i.error !== null && (
        <p className={`notice ${i.status === "failed" ? "danger-notice" : ""}`}>
          <span className="body">{i.error}</span>
        </p>
      )}
      {importLive(i) && (
        <div className="actions">
          <button type="button" className="ghost" disabled={busy} onClick={onCancel}>
            Cancel import
          </button>
        </div>
      )}
      <div className="table-scroll">
        <table className="stats">
          <caption className="sr-only">What the import found so far</caption>
          <thead>
            <tr>
              <th scope="col">Count</th>
              <th scope="col">n</th>
              <th scope="col">What it counts</th>
            </tr>
          </thead>
          <tbody>
            {importStats.map((k) => (
              <tr key={k.key}>
                <th scope="row">{k.label}</th>
                <td className="data">{i.stats[k.key] ?? 0}</td>
                <td className="small-text mute">{k.means}</td>
              </tr>
            ))}
            {Object.entries(i.stats)
              .filter(([k]) => !importStats.some((s) => s.key === k))
              .map(([k, v]) => (
                <tr key={k}>
                  <th scope="row" className="data">
                    {k}
                  </th>
                  <td className="data">{v}</td>
                  <td className="small-text mute">A count this version does not know.</td>
                </tr>
              ))}
          </tbody>
        </table>
      </div>
    </article>
  );
}