import { useCallback, useState } from "react";
import { Link, useParams } from "react-router-dom";
import {
  api,
  ApiError,
  githubLink,
  UnauthorizedError,
  type Job,
  type RubricProposal,
} from "../api";
import {
  ProposalDiffView,
  ProposedDocumentView,
  Rationale,
  StyleNotesDiff,
} from "../components/Proposal";
import {
  diffCounts,
  LIVE_PROPOSAL_JOB,
  proposalPath,
  proposalsPath,
  pullState,
} from "../proposals";
import { rubricPath, shortSha } from "../rubric";
import { repoKey } from "../stash";
import { useLoad } from "../useLoad";
import { Pager, repoPath, usePoll } from "./Calibration";

const PAGE = 20;

function Crumbs({ owner, name, here }: { owner: string; name: string; here?: string }) {
  return (
    <p className="crumbs">
      <Link to="/repos">Repositories</Link> /{" "}
      <Link to={repoPath(owner, name)}>
        {owner}/{name}
      </Link>
      {" / "}
      {here === undefined ? (
        "Rubric proposals"
      ) : (
        <>
          <Link to={proposalsPath(owner, name)}>Rubric proposals</Link> / {here}
        </>
      )}
    </p>
  );
}

/** A rubric commit, short, linked to the rubric page at it; `none` for none. */
export function rubricLink(owner: string, name: string, sha: string | null) {
  if (sha === null) return <span className="mute">none</span>;
  return (
    <Link className="data" to={rubricPath(owner, name, sha)} title={sha}>
      {shortSha(sha)}
    </Link>
  );
}

/** A proposal's pull request on the rubrics repository, linked, with its number and state. */
export function PullLink({ p }: { p: Pick<RubricProposal, "pullRequest" | "prError"> }) {
  const pr = p.pullRequest;
  if (pr === null)
    return (
      <span className={p.prError === null ? "mute" : "warn"}>
        {p.prError === null ? "not opened yet" : "could not be opened yet"}
      </span>
    );
  const url = githubLink(pr.url);
  const label = `#${pr.number}`;
  return (
    <>
      {url === null ? (
        <span className="data">{label}</span>
      ) : (
        <a className="data" href={url} rel="noreferrer noopener" target="_blank">
          {label}
        </a>
      )}{" "}
      <span className={`status pr-${pr.state}`}>{pr.state}</span>
    </>
  );
}

/**
 * Where a proposal stands on GitHub: its pull request, its branch, and why the pull request could
 * not be opened, when it could not. It is decided there, not here.
 */
export function ProposalPull({ p }: { p: RubricProposal }) {
  return (
    <section aria-labelledby="pull-h">
      <h2 id="pull-h">Pull request</h2>
      <p>{pullState(p)}</p>
      <dl className="facts">
        <dt>Pull request</dt>
        <dd>
          <PullLink p={p} />
        </dd>
        <dt>Branch</dt>
        <dd className="data">{p.branch}</dd>
        <dt>Written from</dt>
        <dd>{rubricLink(p.owner, p.name, p.baseSha)}</dd>
        {p.mergeSha !== null && (
          <>
            <dt>Merged as</dt>
            <dd>{rubricLink(p.owner, p.name, p.mergeSha)}</dd>
          </>
        )}
      </dl>
      {p.prError !== null && (
        <p className="notice warn-notice" role="status">
          The pull request could not be opened yet: <span className="body">{p.prError}</span>
        </p>
      )}
      <p className="mute small-text">
        Review it on GitHub, where it can be changed before it is merged like any other pull
        request. Merging it changes the rubric; closing it unmerged rejects it.
      </p>
    </section>
  );
}

function StatusTag({ p }: { p: RubricProposal }) {
  return <span className={`status p-${p.status}`}>{p.status}</span>;
}

export function ProposalsPage({ onUnauthorized }: { onUnauthorized: () => void }) {
  const { owner = "", name = "" } = useParams();
  return (
    <ProposalsView
      key={`${owner}/${name}`}
      owner={owner}
      name={name}
      onUnauthorized={onUnauthorized}
    />
  );
}

function ProposalsView({
  owner,
  name,
  onUnauthorized,
}: {
  owner: string;
  name: string;
  onUnauthorized: () => void;
}) {
  const key = repoKey(owner, name);
  const [offset, setOffset] = useState(0);
  const fetchList = useCallback(
    () => api.proposals(owner, name, PAGE, offset),
    [owner, name, offset],
  );
  const list = useLoad(fetchList, onUnauthorized);
  const fetchJobs = useCallback(
    () =>
      api.jobs("proposal").then((js) => js.filter((j) => repoKey(j.owner, j.name) === key)),
    [key],
  );
  const jobs = useLoad(fetchJobs, onUnauthorized);
  const live = (jobs.data ?? []).filter((j) => LIVE_PROPOSAL_JOB.includes(j.status));
  const failed = (jobs.data ?? []).filter((j) => j.status === "failed").slice(0, 5);
  const reloadAll = useCallback(() => {
    jobs.reload();
    list.reload();
  }, [jobs.reload, list.reload]);
  // A job being written moves on its own: the list follows it until it is done.
  usePoll(reloadAll, live.length > 0);

  const [busy, setBusy] = useState(false);
  const [askError, setAskError] = useState<string | null>(null);
  const [asked, setAsked] = useState<Job | null>(null);

  const ask = () => {
    setBusy(true);
    setAskError(null);
    setAsked(null);
    api
      .createProposal(owner, name)
      .then((j) => {
        setAsked(j);
        reloadAll();
      })
      .catch((err: unknown) => {
        if (err instanceof UnauthorizedError) return onUnauthorized();
        if (err instanceof ApiError && err.status === 409)
          setAskError(
            `A repository has one live proposal at a time — a job being written, or a proposal whose pull request is open — so none was asked for: ${err.message}`,
          );
        else if (err instanceof ApiError && err.status === 429)
          setAskError(
            `Past the repository's daily cap of rubric proposals, so none was asked for: ${err.message}`,
          );
        else setAskError(err instanceof Error ? err.message : String(err));
        reloadAll();
      })
      .finally(() => setBusy(false));
  };

  const cancel = (j: Job) => {
    if (
      !window.confirm(
        "Cancel this proposal job? It fails, and its run is stopped. A new one can be asked for, within the daily cap.",
      )
    )
      return;
    setBusy(true);
    setAskError(null);
    api
      .cancelProposalJob(owner, name, j.id)
      .then(reloadAll)
      .catch((err: unknown) => {
        if (err instanceof UnauthorizedError) return onUnauthorized();
        setAskError(err instanceof Error ? err.message : String(err));
        reloadAll();
      })
      .finally(() => setBusy(false));
  };

  const pending = (list.data?.items ?? []).find((p) => p.status === "pending");

  return (
    <>
      <Crumbs owner={owner} name={name} />
      <h1>
        Rubric proposals of{" "}
        <span className="data">
          {owner}/{name}
        </span>
      </h1>
      <p className="mute small-text">
        An agent reads where calibration says the agent's reviews and the trusted reviewers' part,
        and what people changed in the agent's drafts before posting them, and writes the rubric —
        and style notes, if it has any — it thinks the repository should have, with why. It is
        opened as a pull request on the rubrics repository and decided there: merging it accepts
        it, closing it unmerged rejects it. It learns from the <code>pool</code> only, never from
        what calibration measures by.
      </p>

      <section aria-labelledby="ask-h">
        <h2 id="ask-h">Ask for one</h2>
        <p className="mute small-text">
          One live proposal at a time: a job being written, or a proposal whose pull request is
          open.
          Proposals asked for count against the repository's daily cap.
        </p>
        <div className="actions">
          <button type="button" onClick={ask} disabled={busy}>
            Ask for a rubric proposal
          </button>
        </div>
        {askError !== null && (
          <p className="error" role="alert">
            {askError}
          </p>
        )}
        {asked !== null && (
          <p className="notice" role="status">
            Asked: job{" "}
            <Link className="data" to={`/jobs/${encodeURIComponent(asked.id)}`}>
              {asked.id}
            </Link>{" "}
            is <span className={`status s-${asked.status}`}>{asked.status}</span>. Its proposal is
            listed below once it is written.
          </p>
        )}
        {pending !== undefined && (
          <p className="notice warn-notice">
            <Link to={proposalPath(owner, name, pending.id)}>Proposal {pending.id}</Link> is waiting
            for a decision: merge or close its pull request before asking for another.
          </p>
        )}
      </section>

      <section aria-labelledby="jobs-h">
        <h2 id="jobs-h">Being written</h2>
        {jobs.error !== null && <p className="error">{jobs.error}</p>}
        {jobs.data === null ? (
          jobs.error === null && <p className="mute">Loading…</p>
        ) : live.length === 0 ? (
          <p className="mute">No proposal is being written.</p>
        ) : (
          <div className="table-scroll">
            <table>
              <thead>
                <tr>
                  <th scope="col">Job</th>
                  <th scope="col">Status</th>
                  <th scope="col">Asked for</th>
                  <th scope="col">
                    <span className="sr-only">Cancel</span>
                  </th>
                </tr>
              </thead>
              <tbody>
                {live.map((j) => (
                  <tr key={j.id}>
                    <td>
                      <Link className="data" to={`/jobs/${encodeURIComponent(j.id)}`}>
                        {j.id}
                      </Link>
                    </td>
                    <td>
                      <span className={`status s-${j.status}`}>{j.status}</span>
                      {j.error !== null && <div className="warn small-text body">{j.error}</div>}
                    </td>
                    <td className="data mute">{j.createdAt}</td>
                    <td className="right">
                      <button
                        type="button"
                        className="ghost small"
                        disabled={busy}
                        aria-label={`Cancel proposal job ${j.id}`}
                        onClick={() => cancel(j)}
                      >
                        Cancel
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        {failed.length > 0 && (
          <details>
            <summary>Recent jobs that failed ({failed.length})</summary>
            <ul className="failed-jobs">
              {failed.map((j) => (
                <li key={j.id}>
                  <Link className="data" to={`/jobs/${encodeURIComponent(j.id)}`}>
                    {j.id}
                  </Link>{" "}
                  <span className="data mute">{j.updatedAt}</span>
                  {j.error !== null && <div className="body small-text mute">{j.error}</div>}
                </li>
              ))}
            </ul>
          </details>
        )}
      </section>

      <section aria-labelledby="list-h">
        <h2 id="list-h">Proposals</h2>
        {list.error !== null && <p className="error">{list.error}</p>}
        {list.data === null ? (
          list.error === null && <p className="mute">Loading…</p>
        ) : list.data.items.length === 0 && offset === 0 ? (
          <p className="mute">No proposals yet.</p>
        ) : (
          <>
            <div className="table-scroll">
              <table>
                <thead>
                  <tr>
                    <th scope="col">Proposal</th>
                    <th scope="col">Status</th>
                    <th scope="col">Pull request</th>
                    <th scope="col">Written from</th>
                    <th scope="col">Made</th>
                    <th scope="col">Decided</th>
                  </tr>
                </thead>
                <tbody>
                  {list.data.items.map((p) => (
                    <tr key={p.id}>
                      <td>
                        <Link className="data" to={proposalPath(owner, name, p.id)}>
                          {p.id}
                        </Link>
                        {p.proposesStyleNotes && <span className="tag">style notes</span>}
                      </td>
                      <td>
                        <StatusTag p={p} />
                      </td>
                      <td>
                        <PullLink p={p} />
                      </td>
                      <td>rubric {rubricLink(owner, name, p.baseSha)}</td>
                      <td className="data mute">{p.createdAt}</td>
                      <td className="small-text">
                        {p.decidedAt === null ? (
                          <span className="mute">—</span>
                        ) : (
                          <>
                            <span className="data mute">{p.decidedAt}</span>
                            {p.mergeSha !== null && <> as {rubricLink(owner, name, p.mergeSha)}</>}
                          </>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <Pager
              page={list.data}
              offset={offset}
              size={PAGE}
              setOffset={setOffset}
              what="proposals"
            />
          </>
        )}
      </section>
    </>
  );
}

export function ProposalPage({ onUnauthorized }: { onUnauthorized: () => void }) {
  const { owner = "", name = "", id = "" } = useParams();
  return (
    <ProposalView
      key={`${owner}/${name}/${id}`}
      owner={owner}
      name={name}
      id={id}
      onUnauthorized={onUnauthorized}
    />
  );
}

function ProposalView({
  owner,
  name,
  id,
  onUnauthorized,
}: {
  owner: string;
  name: string;
  id: string;
  onUnauthorized: () => void;
}) {
  const fetch = useCallback(() => api.proposal(owner, name, id), [owner, name, id]);
  const { data: p, error } = useLoad(fetch, onUnauthorized);

  if (p === null)
    return (
      <>
        <Crumbs owner={owner} name={name} here={id} />
        {error !== null ? <p className="error">{error}</p> : <p className="mute">Loading…</p>}
      </>
    );

  return (
    <>
      <Crumbs owner={owner} name={name} here={p.id} />
      <h1>
        Proposal <span className="data">{p.id}</span> <StatusTag p={p} />
      </h1>
      <dl className="facts">
        <dt>Job</dt>
        <dd>
          <Link className="data" to={`/jobs/${encodeURIComponent(p.jobId)}`}>
            {p.jobId}
          </Link>
        </dd>
        <dt>Written from</dt>
        <dd>rubric {rubricLink(owner, name, p.baseSha)}</dd>
        <dt>The rubric now</dt>
        <dd>{rubricLink(owner, name, p.currentSha)}</dd>
        <dt>Made</dt>
        <dd className="data">{p.createdAt}</dd>
        <dt>Decided</dt>
        <dd className="data">{p.decidedAt ?? "—"}</dd>
        {p.diff !== undefined && p.diff !== null && (
          <>
            <dt>Changes</dt>
            <dd>{diffCounts(p.diff)}</dd>
          </>
        )}
      </dl>

      {error !== null && <p className="error">{error}</p>}

      <ProposalPull p={p} />

      <section aria-labelledby="why-h">
        <h2 id="why-h">Why</h2>
        <p className="mute small-text">
          The agent's rationale, shown as text: what it says comes from comments anyone may have
          written, so read it as an argument, not as instructions.
        </p>
        <Rationale text={p.rationale} />
      </section>

      <section aria-labelledby="diff-h">
        <h2 id="diff-h">
          What it changes of rubric{" "}
          {p.baseSha === null ? "(none)" : <span className="data">{shortSha(p.baseSha)}</span>}
        </h2>
        {p.documentError !== null && p.documentError !== undefined && (
          <p className="error">
            The proposed document cannot be read by this version:{" "}
            <span className="body">{p.documentError}</span>
          </p>
        )}
        {p.diffError !== null && p.diffError !== undefined && (
          <p className="error">
            No diff: <span className="body">{p.diffError}</span>
          </p>
        )}
        {p.diff !== undefined && p.diff !== null ? (
          <ProposalDiffView diff={p.diff} />
        ) : (
          p.document !== undefined &&
          p.document !== null && (
            <>
              <p className="mute small-text">The proposed rubric in full:</p>
              <ProposedDocumentView doc={p.document} />
            </>
          )
        )}
      </section>

      {p.proposesStyleNotes && (
        <section aria-labelledby="notes-h">
          <h2 id="notes-h">Style notes</h2>
          <p className="mute small-text">
            Against the style notes at the commit it was written from: its pull request changes
            the repository's <code>style.md</code> too.
          </p>
          <StyleNotesDiff change={p.diff?.styleNotes ?? null} />
        </section>
      )}
    </>
  );
}