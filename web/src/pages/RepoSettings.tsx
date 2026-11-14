import { useCallback, useContext, useEffect, useMemo, useState, type FormEvent } from "react";
import { Link, useBlocker, useParams } from "react-router-dom";
import { api, ApiError, UnauthorizedError, type PostingMode, type Repo } from "../api";
import { proposalsPath } from "../proposals";
import {
  addLogins,
  evalShareProblem,
  formOf,
  formProblem,
  MAX_TRUSTED_REVIEWERS,
  mergeRepoSettings,
  openConflicts,
  putBody,
  resolveRepoConflict,
  sameForm,
  saveRefusal,
  type RepoConflict,
  type RepoForm,
  type RepoPicks,
} from "../repoSettings";
import { rubricPath } from "../rubric";
import {
  dropRepoStash,
  repoKey,
  reopenRepo,
  stashRepo,
  unstashRepo,
  type RepoEdits,
  type StashedRepo,
} from "../stash";

/** A move onto a newer version that met conflicts: what it moved, and the sides picked. */
interface Rebased {
  from: number;
  source: RepoEdits;
  picks: RepoPicks;
  conflicts: RepoConflict[];
}
import { UnsavedContext } from "../unsaved";
import { useLoad } from "../useLoad";
import { repoPath } from "./Calibration";

/** The repository named, from the list: there is no route for one alone. */
async function findRepo(owner: string, name: string): Promise<Repo> {
  const key = repoKey(owner, name);
  const r = (await api.repos()).find((x) => repoKey(x.owner, x.name) === key);
  if (r === undefined) throw new ApiError(404, `${owner}/${name} is not registered`);
  return r;
}

export function RepoSettingsPage({ onUnauthorized }: { onUnauthorized: () => void }) {
  const { owner = "", name = "" } = useParams();
  return (
    <RepoSettingsView
      key={`${owner}/${name}`}
      owner={owner}
      name={name}
      onUnauthorized={onUnauthorized}
    />
  );
}

const fieldLabel: Record<RepoConflict["field"], string> = {
  mode: "Posting mode",
  autoReview: "Automatic reviews",
  evalShare: "Share held out",
};

function show(c: RepoConflict, v: RepoConflict["mine"]): string {
  if (c.field === "autoReview") return v ? "on" : "off";
  if (c.field === "evalShare") return `${String(v)}%`;
  return String(v);
}

function RepoSettingsView({
  owner,
  name,
  onUnauthorized,
}: {
  owner: string;
  name: string;
  onUnauthorized: () => void;
}) {
  const key = repoKey(owner, name);
  const fetch = useCallback(() => findRepo(owner, name), [owner, name]);
  const { data: repo, error, setError, setData: setRepo } = useLoad(fetch, onUnauthorized);
  const [edits, setEdits] = useState<RepoEdits | null>(null);
  // Where a move onto a newer version met a setting both sides changed: the edits from before the
  // move (kept, so that the conflicts can be worked out again after a reload) and the sides picked.
  const [rebased, setRebased] = useState<Rebased | null>(null);
  const [moved, setMoved] = useState<string | null>(null);
  // A 409 that was not about the version, as the server put it: the edits are kept as they were.
  const [refused, setRefused] = useState<string | null>(null);
  const [saved, setSaved] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [login, setLogin] = useState("");
  const [loginError, setLoginError] = useState<string | null>(null);
  const [memoryOnly, setMemoryOnly] = useState(false);
  const [offer, setOffer] = useState<StashedRepo | null>(() => {
    const s = unstashRepo(key);
    return s !== null && (s.pending !== null || !sameForm(s.base, s.form)) ? s : null;
  });

  const base = useMemo(() => (repo === null ? null : formOf(repo)), [repo]);
  const form = edits?.form ?? base;
  const open = rebased === null ? [] : openConflicts(rebased.conflicts, rebased.picks);
  const dirty = edits !== null && (open.length > 0 || !sameForm(edits.base, edits.form));

  // Kept in the tab's storage on every change, with the conflicts still open and the sides picked
  // so far, so that a 401 or a reload loses nothing.
  useEffect(() => {
    if (edits === null) return;
    const pending =
      rebased !== null && openConflicts(rebased.conflicts, rebased.picks).length > 0
        ? { from: rebased.from, source: rebased.source, picks: rebased.picks }
        : null;
    setMemoryOnly(!stashRepo(edits, pending));
  }, [edits, rebased]);

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
        "These settings have unsaved changes. Leave anyway? They are kept in this tab and offered back when you open them again.",
      )
    )
      blocker.proceed();
    else blocker.reset();
  }, [blocker]);


  if (repo === null || base === null || form === null)
    return (
      <>
        <Crumbs owner={owner} name={name} />
        {error !== null ? <p className="error">{error}</p> : <p className="mute">Loading…</p>}
      </>
    );

  const change = (f: (x: RepoForm) => RepoForm) => {
    setSaved(null);
    setEdits((e) =>
      e === null
        ? { repo: key, version: repo.version, base, form: f(base) }
        : { ...e, form: f(e.form) },
    );
  };

  /** Move edits made to `e.base` onto `theirs`, saying where both changed one setting. */
  const mergeOnto = (theirs: Repo, e: RepoEdits) => {
    setRepo(theirs);
    const t = formOf(theirs);
    const m = mergeRepoSettings(e.base, e.form, t);
    setRebased(
      m.conflicts.length > 0
        ? { from: e.version, source: e, picks: {}, conflicts: m.conflicts }
        : null,
    );
    if (m.conflicts.length === 0 && sameForm(m.form, t)) {
      setEdits(null);
      dropRepoStash(key);
      setMoved(
        `The settings were changed elsewhere (now version ${theirs.version}); they already say what your changes did.`,
      );
      return;
    }
    setEdits({ repo: key, version: theirs.version, base: t, form: m.form });
    setMoved(
      `The settings were changed elsewhere (version ${e.version}, now ${theirs.version}), so nothing was saved. Your changes are moved onto the new version${m.conflicts.length > 0 ? "; where both changed the same setting, choose below" : ""}. Check them and save again.`,
    );
  };

  const save = () => {
    const sent = edits;
    if (sent === null || open.length > 0 || formProblem(sent.form) !== null) return;
    setBusy(true);
    setError(null);
    setMoved(null);
    setRefused(null);
    // The fields read at the version the edits are to: a newer build's settings among them.
    const read: Repo = { ...repo, version: sent.version };
    const body = putBody(read, sent.form);
    api
      .putRepoSettings(repo.owner, repo.name, body)
      .then((r) => {
        setRepo(r);
        setEdits(null);
        setRebased(null);
        dropRepoStash(key);
        setSaved(`Saved as version ${r.version}.`);
      })
      .catch((err: unknown) => {
        if (err instanceof UnauthorizedError) return onUnauthorized();
        if (err instanceof ApiError && err.status === 409) {
          findRepo(owner, name)
            .then((theirs) => {
              const why = saveRefusal(sent.version, theirs, err.message);
              if (why === null) mergeOnto(theirs, sent);
              else setRefused(why);
            })
            .catch((e2: unknown) =>
              e2 instanceof UnauthorizedError
                ? onUnauthorized()
                : setError(e2 instanceof Error ? e2.message : String(e2)),
            );
          return;
        }
        setError(err instanceof Error ? err.message : String(err));
      })
      .finally(() => setBusy(false));
  };

  const discard = () => {
    setEdits(null);
    setRebased(null);
    setMoved(null);
    setRefused(null);
    dropRepoStash(key);
  };


  const pick = (c: RepoConflict, which: "mine" | "theirs") => {
    change((f) => resolveRepoConflict(f, c, which));
    setRebased((rb) => (rb === null ? rb : { ...rb, picks: { ...rb.picks, [c.field]: which } }));
  };

  const restore = () => {
    if (offer === null) return;
    setOffer(null);
    if (offer.pending === null) {
      // A stash from before the share held out has it made up alike on both sides: merged, it
      // is the settings' own.
      if (offer.version === repo.version && offer.legacy !== true)
        setEdits({ repo: key, version: offer.version, base: offer.base, form: offer.form });
      else mergeOnto(repo, offer);
      return;
    }
    const back = reopenRepo(offer);
    if (back === null || back.pending === null) {
      // The open conflicts cannot be worked out again: the edits from before them are moved anew.
      mergeOnto(repo, offer.pending.source);
      return;
    }
    setEdits(back.edits);
    setRebased({ ...back.pending, conflicts: back.conflicts });
    if (offer.version !== repo.version)
      setMoved(
        `The settings are at version ${repo.version} now. Settle the conflicts below first; saving then moves your changes onto version ${repo.version}.`,
      );
  };

  const add = (e: FormEvent) => {
    e.preventDefault();
    const r = addLogins(form.trustedReviewers, login);
    if ("problem" in r) {
      setLoginError(r.problem);
      return;
    }
    setLoginError(null);
    setLogin("");
    change((f) => ({ ...f, trustedReviewers: r.list }));
  };

  const problem = formProblem(form);
  const editable = offer === null;
  // A server older than API 0.6.0 has none: its field is not shown.
  const hasShare = typeof repo.evalShare === "number";

  return (
    <>
      <Crumbs owner={owner} name={name} />
      <h1>
        Settings of{" "}
        <span className="data">
          {repo.owner}/{repo.name}
        </span>
      </h1>
      <dl className="facts">
        <dt>Version</dt>
        <dd className="data">{repo.version}</dd>
        <dt>Registered</dt>
        <dd className="data">{repo.createdAt}</dd>
      </dl>
      <p className="actions">
        <Link to={`${repoPath(repo.owner, repo.name)}/rubric`}>Rubric</Link>
        <Link to={`${repoPath(repo.owner, repo.name)}/calibration`}>Calibration</Link>
        <Link to={proposalsPath(repo.owner, repo.name)}>Rubric proposals</Link>
      </p>

      {offer !== null && (
        <div className="notice warn-notice" role="alert">
          <p>
            This tab holds unsaved changes to these settings from earlier (made to version{" "}
            {offer.version}, kept {offer.savedAt}).
            {offer.version !== repo.version &&
              ` The settings are at version ${repo.version} now; restoring moves your changes onto it, and asks where both changed the same setting.`}
          </p>
          <div className="actions">
            <button type="button" onClick={restore}>
              Restore them
            </button>
            <button
              type="button"
              className="ghost"
              onClick={() => {
                dropRepoStash(key);
                setOffer(null);
              }}
            >
              Discard them
            </button>
          </div>
        </div>
      )}
      {error !== null && (
        <p className="error" role="alert">
          {error}
        </p>
      )}
      {refused !== null && (
        <div className="notice warn-notice" role="alert">
          <p>
            Refused, nothing was saved: <span className="body">{refused}</span>
          </p>
        </div>
      )}
      {moved !== null && (
        <p className="notice warn-notice" role="alert">
          {moved}
        </p>
      )}
      {saved !== null && !dirty && (
        <p className="notice" role="status">
          {saved}
        </p>
      )}
      {(rebased?.conflicts ?? []).map((c) => (
        <fieldset key={c.field} className="conflict">
          <legend>{fieldLabel[c.field]}: changed here and elsewhere</legend>
          <label className="side">
            <input
              type="radio"
              name={`pick-${c.field}`}
              checked={rebased?.picks[c.field] === "mine"}
              onChange={() => pick(c, "mine")}
            />
            Keep mine: <span className="value data">{show(c, c.mine)}</span>
          </label>
          <label className="side">
            <input
              type="radio"
              name={`pick-${c.field}`}
              checked={rebased?.picks[c.field] === "theirs"}
              onChange={() => pick(c, "theirs")}
            />
            Keep the other change: <span className="value data">{show(c, c.theirs)}</span>
          </label>
        </fieldset>
      ))}

      <h2>Reviews</h2>
      <label className="field">
        Posting mode
        <select
          value={form.mode}
          disabled={!editable}
          onChange={(e) => change((f) => ({ ...f, mode: e.target.value as PostingMode }))}
        >
          <option value="staged">staged — a person approves each review before it is posted</option>
          <option value="direct">direct — posted as soon as the agent submits it</option>
        </select>
      </label>
      <label className="check">
        <input
          type="checkbox"
          checked={form.autoReview}
          disabled={!editable}
          onChange={(e) => change((f) => ({ ...f, autoReview: e.target.checked }))}
        />
        Review open pull requests on its own
      </label>

      <h2 id="trusted-h">Trusted reviewers</h2>
      <p className="mute small-text">
        The GitHub logins whose past reviews calibration imports and scores the agent against: the
        people whose judgement the agent's reviews should come close to. At most{" "}
        {MAX_TRUSTED_REVIEWERS}; stored in lower case.
      </p>
      {form.trustedReviewers.length === 0 ? (
        <p className="mute">None yet: calibration cannot import anything until one is named.</p>
      ) : (
        <ul className="logins" aria-labelledby="trusted-h">
          {form.trustedReviewers.map((l) => (
            <li key={l}>
              <span className="data">{l}</span>
              <button
                type="button"
                className="ghost small"
                disabled={!editable}
                aria-label={`Remove ${l}`}
                onClick={() =>
                  change((f) => ({
                    ...f,
                    trustedReviewers: f.trustedReviewers.filter((x) => x !== l),
                  }))
                }
              >
                Remove
              </button>
            </li>
          ))}
        </ul>
      )}
      <form className="inline" onSubmit={add}>
        <input
          aria-label="GitHub login to trust"
          aria-describedby={loginError !== null ? "login-error" : undefined}
          aria-invalid={loginError !== null}
          placeholder="GitHub login(s)"
          className="data"
          value={login}
          disabled={!editable}
          onChange={(e) => {
            setLogin(e.target.value);
            setLoginError(null);
          }}
        />
        <button type="submit" disabled={!editable || login.trim() === ""}>
          Add
        </button>
      </form>
      {loginError !== null && (
        <p id="login-error" className="error small-text" role="alert">
          {loginError}
        </p>
      )}

      <h2 id="notes-h">Review style</h2>
      <p className="mute small-text">
        What the agent should know of how reviews here are written that examples cannot show — "one
        sentence a comment", "no praise", "suggest, don't ask" — is in the style notes, which live
        in the rubrics repository with the rubric, as{" "}
        <code>
          {repo.owner}/{repo.name}/style.md
        </code>
        : the agent's instructions end with them. They are changed by a commit or a pull request
        there; the <Link to={rubricPath(repo.owner, repo.name)}>rubric page</Link> shows them and
        links to the file.
      </p>

      {hasShare && (
        <>
          <h2 id="share-h">Calibration: held out</h2>
          <label className="field">
            Share of pull requests held out for measuring, in percent
            <input
              type="number"
              min={0}
              max={100}
              step={1}
              inputMode="numeric"
              className="narrow"
              value={Number.isNaN(form.evalShare) ? "" : form.evalShare}
              readOnly={!editable}
              aria-describedby="share-help"
              aria-invalid={evalShareProblem(form.evalShare) !== null}
              onChange={(e) => {
                const v = e.target.value === "" ? Number.NaN : Number(e.target.value);
                change((f) => ({ ...f, evalShare: v }));
              }}
            />
          </label>
          <p id="share-help" className="mute small-text">
            Each pull request's calibration samples are held out as <code>eval</code> (what runs
            measure by) or put in the <code>pool</code> (what the style examples and rubric
            proposals learn from), by a stable hash of the pull request against this share; 50 by
            default. A split already made never changes: a new share splits only the pull requests
            that come after it.
          </p>
        </>
      )}

      {dirty && (
        <div className="savebar" role="region" aria-label="Unsaved changes">
          <span>
            Unsaved changes to the settings.
            {memoryOnly && " This tab cannot store them, so they are held in memory only."}
            {open.length > 0 && " Choose a side for each conflict above before saving."}
            {problem !== null && <span className="warn"> {problem}</span>}
          </span>
          <span className="actions">
            <button
              type="button"
              onClick={save}
              disabled={busy || open.length > 0 || problem !== null}
            >
              Save settings
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

function Crumbs({ owner, name }: { owner: string; name: string }) {
  return (
    <p className="crumbs">
      <Link to="/repos">Repositories</Link> / {owner}/{name}
    </p>
  );
}