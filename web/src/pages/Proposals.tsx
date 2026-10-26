import { useCallback, useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { api, ApiError, UnauthorizedError, type Job, type RubricProposal } from "../api";
import {
  ProposalDiffView,
  ProposedDocumentView,
  Rationale,
  StyleNotesDiff,
} from "../components/Proposal";
import {
  acceptProposal,
  acceptRefusal,
  adoptNotesPath,
  adoptRubricPath,
  diffCounts,
  LIVE_PROPOSAL_JOB,
  proposalPath,
  proposalsPath,
  type AcceptRefusal,
} from "../proposals";
import { rubricStashKey } from "../stash";
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

function rubricLink(owner: string, name: string, v: number) {
  if (v === 0) return <span className="mute">none</span>;
  return <Link to={`${repoPath(owner, name)}/rubric?version=${v}`}>version {v}</Link>;
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
  const key = rubricStashKey(owner, name);
  const [offset, setOffset] = useState(0);
  const fetchList = useCallback(
    () => api.proposals(owner, name, PAGE, offset),
    [owner, name, offset],
  );
  const list = useLoad(fetchList, onUnauthorized);
  const fetchJobs = useCallback(
    () =>
      api.jobs("proposal").then((js) => js.filter((j) => rubricStashKey(j.owner, j.name) === key)),
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
            `A repository has one live proposal at a time — a job being written, or a proposal waiting for a decision — so none was asked for: ${err.message}`,
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
        advisory: nothing changes until a person accepts it, as the next rubric version. It learns
        from the <code>pool</code> only, never from what calibration measures by.
      </p>

      <section aria-labelledby="ask-h">
        <h2 id="ask-h">Ask for one</h2>
        <p className="mute small-text">
          One live proposal at a time: a job being written, or a proposal waiting for a decision.
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
            for a decision: accept or reject it before asking for another.
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
                        {p.rebaseNeeded && (
                          <span
                            className="tag flag-stale"
                            title="The rubric has moved since it was written: rebase it in the editor."
                          >
                            rubric moved
                          </span>
                        )}
                      </td>
                      <td>rubric {rubricLink(owner, name, p.baseVersion)}</td>
                      <td className="data mute">{p.createdAt}</td>
                      <td className="small-text">
                        {p.decidedAt === null ? (
                          <span className="mute">—</span>
                        ) : (
                          <>
                            <span className="data mute">{p.decidedAt}</span>
                            {p.acceptedVersion !== null && (
                              <> as {rubricLink(owner, name, p.acceptedVersion)}</>
                            )}
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
  const { data: p, error, reload, setData } = useLoad(fetch, onUnauthorized);
  const navigate = useNavigate();
  // Off unless ticked: accepting the rubric never writes the notes on its own.
  const [applyNotes, setApplyNotes] = useState(false);
  const [busy, setBusy] = useState(false);
  const [refusal, setRefusal] = useState<(AcceptRefusal & { withNotes: boolean }) | null>(null);
  const [actError, setActError] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);

  const fail = (err: unknown) => {
    if (err instanceof UnauthorizedError) return onUnauthorized();
    setActError(err instanceof Error ? err.message : String(err));
  };

  if (p === null)
    return (
      <>
        <Crumbs owner={owner} name={name} here={id} />
        {error !== null ? <p className="error">{error}</p> : <p className="mute">Loading…</p>}
      </>
    );

  const accept = () => {
    const withNotes = p.proposesStyleNotes && applyNotes;
    setBusy(true);
    setActError(null);
    setRefusal(null);
    setDone(null);
    acceptProposal(p, withNotes)
      .then((r) => {
        setData({ ...p, ...r.proposal });
        setDone(
          `Accepted as rubric version ${r.rubric.version}${withNotes ? ", with its style notes" : ""}.`,
        );
        reload();
      })
      .catch((err: unknown) => {
        const why = acceptRefusal(err);
        if (why === null) return fail(err);
        setRefusal({ ...why, withNotes });
        reload();
      })
      .finally(() => setBusy(false));
  };

  const reject = () => {
    if (!window.confirm("Reject this proposal? Nothing of it is written, and it cannot be undone."))
      return;
    setBusy(true);
    setActError(null);
    setRefusal(null);
    setDone(null);
    api
      .rejectProposal(owner, name, p.id)
      .then((r) => {
        setData({ ...p, ...r });
        setDone("Rejected: nothing of it was written.");
        reload();
      })
      .catch((err: unknown) => {
        if (err instanceof ApiError && err.status === 409) {
          setActError(`Refused: ${err.message}`);
          reload();
        } else fail(err);
      })
      .finally(() => setBusy(false));
  };

  const pendingNow = p.status === "pending";
  const canAdopt = p.status !== "rejected" && p.document !== null && p.document !== undefined;
  const openEditor = () => navigate(adoptRubricPath(p.owner, p.name, p.id));
  const openNotes = () => navigate(adoptNotesPath(p.owner, p.name, p.id));

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
        <dd>rubric {rubricLink(owner, name, p.baseVersion)}</dd>
        <dt>The rubric now</dt>
        <dd>{rubricLink(owner, name, p.currentVersion)}</dd>
        <dt>Made</dt>
        <dd className="data">{p.createdAt}</dd>
        <dt>Decided</dt>
        <dd className="data">{p.decidedAt ?? "—"}</dd>
        {p.acceptedVersion !== null && (
          <>
            <dt>Accepted as</dt>
            <dd>{rubricLink(owner, name, p.acceptedVersion)}</dd>
          </>
        )}
        {p.diff !== undefined && p.diff !== null && (
          <>
            <dt>Changes</dt>
            <dd>{diffCounts(p.diff)}</dd>
          </>
        )}
      </dl>

      {error !== null && <p className="error">{error}</p>}
      {done !== null && (
        <p className="notice" role="status">
          {done}
        </p>
      )}
      {actError !== null && (
        <p className="error" role="alert">
          {actError}
        </p>
      )}
      {refusal !== null && (
        <Refused
          r={refusal}
          proposesNotes={p.proposesStyleNotes}
          canAdopt={canAdopt}
          pending={pendingNow}
          onEditor={openEditor}
          onNotes={openNotes}
        />
      )}
      {p.rebaseNeeded && refusal === null && (
        <div className="notice warn-notice" role="status">
          <p>
            The rubric has moved since this proposal was written (from version {p.baseVersion}, now{" "}
            {p.currentVersion}), so accepting it as it is would be refused: it would overwrite a
            change it never saw. Open it in the editor to move it onto the current rubric, where you
            choose wherever both changed the same thing, and save it there.
          </p>
          {canAdopt && (
            <div className="actions">
              <button type="button" onClick={openEditor}>
                Open in the editor
              </button>
            </div>
          )}
        </div>
      )}

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
          What it changes of rubric {p.baseVersion === 0 ? "(none)" : `version ${p.baseVersion}`}
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
              <p className="mute small-text">
                The proposed document in full, as accepting writes it:
              </p>
              <ProposedDocumentView doc={p.document} />
            </>
          )
        )}
      </section>

      {p.proposesStyleNotes && (
        <section aria-labelledby="notes-h">
          <h2 id="notes-h">Style notes</h2>
          <p className="mute small-text">
            Against the notes its agent was given when it first read its context. Accepting writes
            them only when asked, and only while the repository's notes are still those.
          </p>
          <StyleNotesDiff change={p.diff?.styleNotes ?? null} />
          {canAdopt && (
            <>
              {pendingNow && <NotesOnlyNote />}
              <div className="actions">
                <button type="button" className="ghost" onClick={openNotes}>
                  Open the style notes in the settings…
                </button>
              </div>
            </>
          )}
        </section>
      )}

      {pendingNow && (
        <Decide
          p={p}
          applyNotes={applyNotes}
          setApplyNotes={setApplyNotes}
          busy={busy}
          onAccept={accept}
          onReject={reject}
          onEdit={canAdopt ? openEditor : undefined}
        />
      )}
    </>
  );
}

/**
 * What saving a pending proposal's style notes in the settings does: the save names the proposal,
 * which the new notes version records as what it came from, and decides nothing.
 */
function NotesOnlyNote() {
  return (
    <p className="notice">
      <strong>Saving the style notes in the settings does not decide this proposal:</strong> the
      notes record it as what they came from, and it stays pending, so its rubric can still be
      accepted or rejected here, or saved from the editor.
    </p>
  );
}

/** Whether the page can show what accepting `p` writes: its diff, or else its document. */
function acceptShown(p: Pick<RubricProposal, "diff" | "document">): boolean {
  return (
    (p.diff !== undefined && p.diff !== null) || (p.document !== undefined && p.document !== null)
  );
}

/**
 * Accept or reject a pending proposal, or, with `onEdit`, edit it before accepting: its document
 * opened in the rubric editor as unsaved edits, which saving there accepts. "Also apply the style
 * notes" is shown only when the proposal has some, and is off until the person ticks it.
 * Accepting is not offered when neither the diff nor the document can be shown: nothing is
 * accepted unseen.
 */
export function Decide({
  p,
  applyNotes,
  setApplyNotes,
  busy,
  onAccept,
  onReject,
  onEdit,
}: {
  p: RubricProposal;
  applyNotes: boolean;
  setApplyNotes: (on: boolean) => void;
  busy: boolean;
  onAccept: () => void;
  onReject: () => void;
  onEdit?: (() => void) | undefined;
}) {
  const shown = acceptShown(p);
  return (
    <section aria-labelledby="decide-h" className="decide">
      <h2 id="decide-h">Decide</h2>
      <p className="mute small-text">
        Accepting makes the proposed document rubric version {p.currentVersion + 1}, recording the
        calibration samples its agent drew on. It is checked against the rubric you read here,
        version {p.currentVersion}: if it has moved since, nothing is written.
      </p>
      {!shown && (
        <p className="error small-text">
          Neither what it changes nor the document it proposes can be shown here, so it cannot be
          accepted from this page; it can still be rejected.
        </p>
      )}
      {p.proposesStyleNotes && (
        <label className="check">
          <input
            type="checkbox"
            name="apply-style-notes"
            checked={applyNotes}
            onChange={(e) => setApplyNotes(e.target.checked)}
          />
          Also apply the style notes it proposes, as the repository's
        </label>
      )}
      <div className="actions">
        <button type="button" onClick={onAccept} disabled={busy || !shown}>
          Accept as rubric version {p.currentVersion + 1}
          {p.proposesStyleNotes && applyNotes && ", with the style notes"}
        </button>
        {onEdit !== undefined && (
          <button type="button" className="ghost" onClick={onEdit} disabled={busy}>
            Edit before accepting…
          </button>
        )}
        <button type="button" className="ghost danger" onClick={onReject} disabled={busy}>
          Reject
        </button>
      </div>
      {onEdit !== undefined && (
        <p className="mute small-text">
          Editing opens the proposed document in the rubric editor as unsaved changes on top of
          the rubric as it is now; saving it there accepts the proposal, as the version you saved.
        </p>
      )}
    </section>
  );
}

/** A refused accept, and the way on: the editor for a moved rubric, the settings for notes. */
function Refused({
  r,
  proposesNotes,
  canAdopt,
  pending,
  onEditor,
  onNotes,
}: {
  r: AcceptRefusal & { withNotes: boolean };
  proposesNotes: boolean;
  canAdopt: boolean;
  pending: boolean;
  onEditor: () => void;
  onNotes: () => void;
}) {
  if (r.kind === "moved")
    return (
      <div className="notice warn-notice" role="alert">
        <p>
          Nothing was written: the rubric is at version {r.currentVersion}, and the proposal was
          written from version {r.baseVersion}.{" "}
          <span className="body mute small-text">{r.message}</span>
        </p>
        <p>
          Open it in the editor: its document is put there as unsaved edits on top of version{" "}
          {r.currentVersion}, what only it changed is taken, and where both changed the same thing
          you choose. Saving there names the proposal and accepts it.
          {r.withNotes &&
            proposesNotes &&
            " Its style notes were not applied either: open them in the settings once the rubric is saved."}
        </p>
        {canAdopt && pending && r.withNotes && proposesNotes && <NotesOnlyNote />}
        {canAdopt && (
          <div className="actions">
            <button type="button" onClick={onEditor}>
              Open in the editor
            </button>
            {r.withNotes && proposesNotes && (
              <button type="button" className="ghost" onClick={onNotes}>
                Open the style notes in the settings
              </button>
            )}
          </div>
        )}
      </div>
    );
  return (
    <div className="notice warn-notice" role="alert">
      <p>
        Refused, nothing was written: <span className="body">{r.message}</span>
      </p>
      {r.withNotes && proposesNotes && canAdopt && (
        <>
          <p>
            If the style notes are what was refused, accept without them, and open them in the
            settings, where they are put on top of the notes as they are now.
          </p>
          {pending && <NotesOnlyNote />}
          <div className="actions">
            <button type="button" className="ghost" onClick={onNotes}>
              Open the style notes in the settings
            </button>
          </div>
        </>
      )}
    </div>
  );
}