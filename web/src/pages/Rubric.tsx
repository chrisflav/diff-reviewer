import { useCallback, useEffect, useState, type ReactNode } from "react";
import { Link, useParams, useSearchParams } from "react-router-dom";
import {
  api,
  githubLink,
  UnauthorizedError,
  type PrType,
  type RubricCommit,
  type RubricCompare,
  type RubricView,
} from "../api";
import { ProposalDiffView, StyleNotesDiff } from "../components/Proposal";
import { diffCounts } from "../proposals";
import {
  commitTitle,
  comparePair,
  errorWhere,
  extraFields,
  rubricPath,
  rubricState,
  shortSha,
  showValue,
  togglePick,
  typeExtras,
} from "../rubric";
import { useLoad } from "../useLoad";
import { repoPath } from "./Calibration";

const PAGE = 20;

/** A commit, short, as a link to the rubric at it. */
function CommitLink({ owner, name, sha }: { owner: string; name: string; sha: string }) {
  return (
    <Link className="data" to={rubricPath(owner, name, sha)} title={sha}>
      {shortSha(sha)}
    </Link>
  );
}

/** A link to GitHub, opened apart; the text alone when the address is not GitHub's. */
function GitHubLink({ href, children }: { href: string | null; children: ReactNode }) {
  const url = githubLink(href);
  if (url === null) return <>{children}</>;
  return (
    <a href={url} rel="noreferrer noopener" target="_blank">
      {children}
    </a>
  );
}

export function RubricPage({ onUnauthorized }: { onUnauthorized: () => void }) {
  const { owner = "", name = "" } = useParams();
  return (
    <RubricViewer
      key={`${owner}/${name}`}
      owner={owner}
      name={name}
      onUnauthorized={onUnauthorized}
    />
  );
}

/**
 * A repository's rubric, read only: it lives in the rubrics repository on GitHub, which is where
 * it is changed, by commits and pull requests. The page shows the rubric in use, what is wrong
 * with the branch's head if anything, the files to edit, the commits that changed it and what
 * changed between two of them. `?sha=` shows the rubric at another commit.
 */
function RubricViewer({
  owner,
  name,
  onUnauthorized,
}: {
  owner: string;
  name: string;
  onUnauthorized: () => void;
}) {
  const fetchCurrent = useCallback(() => api.rubrics(owner, name), [owner, name]);
  const { data: current, error } = useLoad(fetchCurrent, onUnauthorized);
  const [params] = useSearchParams();
  const asked = params.get("sha");
  const fetchViewed = useCallback(
    (): Promise<RubricView | null> =>
      asked === null ? Promise.resolve(null) : api.rubricAt(owner, name, asked),
    [owner, name, asked],
  );
  const viewed = useLoad(fetchViewed, onUnauthorized);

  if (current === null)
    return (
      <>
        <Crumbs owner={owner} name={name} />
        {error !== null ? <p className="error">{error}</p> : <p className="mute">Loading…</p>}
      </>
    );

  const state = rubricState(current);
  const repoUrl = current.repository === null ? null : `https://github.com/${current.repository}`;
  const commitUrl = (sha: string) => (repoUrl === null ? null : `${repoUrl}/commit/${sha}`);
  const other = asked !== null && asked !== current.sha;

  return (
    <>
      <Crumbs owner={owner} name={name} />
      <h1>
        Rubric of{" "}
        <span className="data">
          {owner}/{name}
        </span>
      </h1>
      <p className="mute small-text">
        The default rubric is what every review of the repository looks at. A pull request type is a
        kind of change reviewed differently: its description says how to recognise it (the agent
        picks the type by it), its rubric what to look at on top of the default, and its categories
        what its comments are filed under. The style notes say how reviews here are written. All of
        it lives in the rubrics repository on GitHub and goes to the agent as it is written, as
        markdown; it is changed there, by a commit or a pull request, and read here.
      </p>

      {state.kind === "unconfigured" ? (
        <p className="notice warn-notice" role="status">
          Rubrics are not configured: the platform has no rubrics repository (
          <code>DIFF_REVIEWER_RUBRICS_REPO</code>), so every review runs with no rubric and no
          style notes.
        </p>
      ) : (
        <>
          <dl className="facts">
            <dt>Rubrics repository</dt>
            <dd>
              <GitHubLink href={repoUrl}>
                <span className="data">{current.repository}</span>
              </GitHubLink>
            </dd>
            <dt>Branch</dt>
            <dd className="data">{current.branch}</dd>
            <dt>Directory</dt>
            <dd>
              <GitHubLink href={current.treeUrl}>
                <span className="data">{current.directory}</span>
              </GitHubLink>
            </dd>
            <dt>In use</dt>
            <dd>
              {current.sha === null ? (
                <span className="mute">none</span>
              ) : (
                <GitHubLink href={commitUrl(current.sha)}>
                  <span className="data" title={current.sha}>
                    {shortSha(current.sha)}
                  </span>
                </GitHubLink>
              )}
              {current.legacyVersion !== null && (
                <span className="mute"> (exported from version {current.legacyVersion})</span>
              )}
            </dd>
            {current.headSha !== null && current.headSha !== current.sha && (
              <>
                <dt>Branch head</dt>
                <dd>
                  <GitHubLink href={commitUrl(current.headSha)}>
                    <span className="data" title={current.headSha}>
                      {shortSha(current.headSha)}
                    </span>
                  </GitHubLink>
                </dd>
              </>
            )}
            <dt>Checked</dt>
            <dd className="data">{current.checkedAt ?? "—"}</dd>
          </dl>

          {state.kind === "none" && (
            <div className="notice warn-notice" role="status">
              <p>
                There is no rubric to read
                {state.error === null ? "." : <>: {errorText(state.error)}</>}
              </p>
              <p className="mute small-text">Until there is, reviews run with no rubric.</p>
            </div>
          )}
          {state.kind === "rubric" && state.headBroken && current.error !== null && (
            <div className="notice danger-notice" role="alert">
              <p>
                <strong>The head of {current.branch} does not parse</strong>, so the last good
                rubric, at {current.sha === null ? "—" : shortSha(current.sha)}, is in use:{" "}
                {errorText(current.error)}
              </p>
              <p className="mute small-text">
                Fix the file on GitHub; the rubric in use moves on once the head parses again.
              </p>
            </div>
          )}

          {current.sha !== null && <EditLinks v={current} repoUrl={repoUrl} />}
        </>
      )}

      {other && (
        <section className="notice viewed" aria-labelledby="viewed-h">
          <h2 id="viewed-h">
            The rubric at <span className="data">{shortSha(asked)}</span>
          </h2>
          <p className="mute small-text">
            Not the commit in use.{" "}
            <Link to={rubricPath(owner, name)}>Back to the rubric in use</Link>
          </p>
          {viewed.error !== null && <p className="error">{viewed.error}</p>}
          {viewed.data === null ? (
            viewed.error === null && <p className="mute">Loading…</p>
          ) : (
            <>
              {viewed.data.error !== null && (
                <p className="error" role="alert">
                  This commit does not parse: {errorText(viewed.data.error)}
                </p>
              )}
              {viewed.data.legacyVersion !== null && (
                <p className="mute small-text">
                  Exported from version {viewed.data.legacyVersion} of the platform's rubric.
                </p>
              )}
              <ShownRubric v={viewed.data} />
              <Provenance owner={owner} name={name} v={viewed.data} />
            </>
          )}
        </section>
      )}

      {!other && state.kind === "rubric" && (
        <>
          <ShownRubric v={current} />
          <Provenance owner={owner} name={name} v={current} />
        </>
      )}

      {state.kind !== "unconfigured" && (
        <RubricHistory
          owner={owner}
          name={name}
          inUse={current.sha}
          onUnauthorized={onUnauthorized}
        />
      )}
    </>
  );
}

function Crumbs({ owner, name }: { owner: string; name: string }) {
  return (
    <p className="crumbs">
      <Link to="/repos">Repositories</Link> /{" "}
      <Link to={repoPath(owner, name)}>
        {owner}/{name}
      </Link>{" "}
      / Rubric
    </p>
  );
}

/** A rubric error as the page says it: where, then why. */
function errorText(e: { file: string | null; line: number | null; message: string }) {
  const where = errorWhere(e);
  return (
    <>
      {where !== "" && <span className="data">{where}: </span>}
      <span className="body">{e.message}</span>
    </>
  );
}

/** Where to change the rubric: each file at the commit and in GitHub's editor; the directory. */
export function EditLinks({ v, repoUrl }: { v: RubricView; repoUrl: string | null }) {
  const filename = encodeURIComponent(`${v.directory}/rubric.md`);
  const newFile =
    repoUrl === null ? null : `${repoUrl}/new/${encodeURIComponent(v.branch)}?filename=${filename}`;
  return (
    <section aria-labelledby="edit-h">
      <h2 id="edit-h">Edit on GitHub</h2>
      <p className="mute small-text">
        <code>rubric.md</code> holds the default rubric, <code>types/&lt;type&gt;.md</code> each
        pull request type, <code>style.md</code> the style notes. A commit to {v.branch} changes the
        rubric for the next reviews; a pull request lets others look first. Each job records the
        commit it was reviewed against.
      </p>
      {!v.exists ? (
        <p className="notice" role="status">
          The rubrics repository has no directory <span className="data">{v.directory}</span>: the
          repository's reviews have no rubric.{" "}
          {newFile !== null && (
            <GitHubLink href={newFile}>Create its rubric.md on GitHub</GitHubLink>
          )}
        </p>
      ) : (
        <ul className="rubric-files">
          {v.files.map((f) => (
            <li key={f.path}>
              <span className="data">{f.path}</span>{" "}
              <span className="actions">
                <GitHubLink href={f.url}>
                  view at {v.sha === null ? "—" : shortSha(v.sha)}
                </GitHubLink>
                <GitHubLink href={f.editUrl}>edit on {v.branch}</GitHubLink>
              </span>
            </li>
          ))}
          {v.treeUrl !== null && (
            <li>
              <GitHubLink href={v.treeUrl}>The whole directory on {v.branch}</GitHubLink>
            </li>
          )}
        </ul>
      )}
    </section>
  );
}

/** A type's fan-out, its categories and its other front matter, all of it text. */
function ShownType({ t }: { t: PrType }) {
  const extras = typeExtras(t);
  return (
    <div className="shown-type">
      <h4 className="data">
        {t.name}
        {t.fanout === true && <span className="tag">fan-out</span>}
      </h4>
      {t.description !== "" && <p className="body">{t.description}</p>}
      <div className="preview body">
        {t.rubric === "" ? <span className="mute">(no rubric of its own)</span> : t.rubric}
      </div>
      {(t.categories ?? []).length === 0 ? (
        <p className="mute small-text">No categories: free text.</p>
      ) : (
        <dl className="cats-shown">
          {t.categories.map((c, j) => (
            <div key={j}>
              <dt className="data">{c.name}</dt>
              <dd className="body">{c.description}</dd>
            </div>
          ))}
        </dl>
      )}
      {extras.length > 0 && <Extras fields={extras} />}
    </div>
  );
}

/** Front matter this build does not know: shown as it is, as text. */
function Extras({ fields }: { fields: [string, unknown][] }) {
  return (
    <dl className="facts extras">
      {fields.map(([k, v]) => (
        <div key={k}>
          <dt className="data">{k}</dt>
          <dd className="data">{showValue(v)}</dd>
        </div>
      ))}
    </dl>
  );
}

/** The rubric at a commit, all of it as text. */
export function ShownRubric({ v }: { v: RubricView }) {
  if (!v.exists)
    return (
      <p className="mute">
        No rubric at this commit: there is no directory <span className="data">{v.directory}</span>.
      </p>
    );
  const extras = extraFields(v);
  return (
    <section aria-labelledby="shown-h">
      <h2 id="shown-h">Default rubric</h2>
      <p className="mute small-text">
        Fan-out of every review: <strong>{v.fanout ? "on" : "off"}</strong>
        {v.fanout && " (one sub-run per category of the fixed type, and one by the default rubric)"}
        .
      </p>
      <div className="preview body">
        {v.defaultRubric === "" ? <span className="mute">(empty)</span> : v.defaultRubric}
      </div>
      <h2>Pull request types</h2>
      {v.prTypes.length === 0 ? (
        <p className="mute">
          None: every pull request is reviewed by the default rubric, and a comment's category is
          free text.
        </p>
      ) : (
        v.prTypes.map((t, i) => <ShownType key={i} t={t} />)
      )}
      <h2>Style notes</h2>
      <div className="preview body">
        {v.styleNotes === "" ? <span className="mute">(none)</span> : v.styleNotes}
      </div>
      {extras.length > 0 && (
        <>
          <h2>Other fields</h2>
          <p className="mute small-text">
            Front matter of <code>rubric.md</code> this version of the platform does not know.
          </p>
          <Extras fields={extras} />
        </>
      )}
    </section>
  );
}

/**
 * A pull request as the server names it, `owner/name#n`, split; null for anything else, a segment
 * that starts with a dot among them (`..`, which would leave the repository in a link).
 */
function pullOf(key: string): { slug: string; pr: number } | null {
  const m = /^([A-Za-z0-9_-][A-Za-z0-9._-]*\/[A-Za-z0-9_-][A-Za-z0-9._-]*)#([0-9]+)$/.exec(key);
  return m === null ? null : { slug: m[1] as string, pr: Number(m[2]) };
}

/**
 * The provenance of a rubric: the calibration samples and pull requests the proposals that reached
 * it drew on. A score of any of them, made under it, is derived: left out of calibration's
 * aggregates unless asked.
 */
function Provenance({ owner, name, v }: { owner: string; name: string; v: RubricView }) {
  const samples = v.derivedFrom ?? [];
  const pulls = v.derivedFromPulls ?? [];
  const base = `${repoPath(owner, name)}/calibration`;
  return (
    <section className="provenance" aria-labelledby="provenance-h">
      <h2 id="provenance-h">Derived from</h2>
      {samples.length === 0 && pulls.length === 0 ? (
        <p className="mute small-text">Nothing: no rubric proposal reached this rubric.</p>
      ) : (
        <>
          <p className="mute small-text">
            What the rubric proposals that reached this rubric drew on. Calibration scores of these
            pull requests made under it are derived: left out of the aggregates unless asked.
          </p>
          <h3>Pull requests ({pulls.length})</h3>
          {pulls.length === 0 ? (
            <p className="mute small-text">None.</p>
          ) : (
            <ul className="chips">
              {pulls.map((k) => {
                const p = pullOf(k);
                return (
                  <li key={k} className="data">
                    {p === null ? (
                      k
                    ) : (
                      <a
                        href={`https://github.com/${p.slug}/pull/${p.pr}`}
                        rel="noreferrer noopener"
                        target="_blank"
                      >
                        {k}
                      </a>
                    )}
                  </li>
                );
              })}
            </ul>
          )}
          <h3>Calibration samples ({samples.length})</h3>
          {samples.length === 0 ? (
            <p className="mute small-text">None.</p>
          ) : (
            <ul className="chips">
              {samples.map((id) => (
                <li key={id} className="data">
                  <Link to={`${base}/samples/${encodeURIComponent(id)}`}>{id}</Link>
                </li>
              ))}
            </ul>
          )}
        </>
      )}
    </section>
  );
}

/**
 * The commits of the rubrics repository that changed this repository's rubric, newest first, a
 * page at a time; two of them picked are compared, as a proposal's diff is shown. The comparison
 * is in the address (`?base=&head=`), so that it can be linked to.
 */
function RubricHistory({
  owner,
  name,
  inUse,
  onUnauthorized,
}: {
  owner: string;
  name: string;
  inUse: string | null;
  onUnauthorized: () => void;
}) {
  const [params, setParams] = useSearchParams();
  const base = params.get("base");
  const head = params.get("head");
  const [items, setItems] = useState<RubricCommit[] | null>(null);
  const [next, setNext] = useState<number | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [picked, setPicked] = useState<string[]>(() =>
    base !== null && head !== null ? [base, head] : [],
  );
  const [compare, setCompare] = useState<RubricCompare | null>(null);
  const [compareError, setCompareError] = useState<string | null>(null);

  const fail = useCallback(
    (set: (e: string) => void) => (err: unknown) => {
      if (err instanceof UnauthorizedError) onUnauthorized();
      else set(err instanceof Error ? err.message : String(err));
    },
    [onUnauthorized],
  );

  useEffect(() => {
    let live = true;
    api
      .rubricHistory(owner, name, PAGE, 0)
      .then((p) => {
        if (!live) return;
        setItems(p.items);
        setNext(p.nextOffset);
      })
      .catch((err: unknown) => live && fail(setError)(err));
    return () => {
      live = false;
    };
  }, [owner, name, fail]);

  // The comparison the address names.
  useEffect(() => {
    setCompare(null);
    setCompareError(null);
    if (base === null || head === null) return;
    let live = true;
    api
      .compareRubrics(owner, name, base, head)
      .then((c) => {
        if (!live) return;
        setCompare(c);
        requestAnimationFrame(() => document.getElementById("compare-h")?.focus());
      })
      .catch((err: unknown) => live && fail(setCompareError)(err));
    return () => {
      live = false;
    };
  }, [owner, name, base, head, fail]);

  const more = () => {
    if (next === null) return;
    setBusy(true);
    api
      .rubricHistory(owner, name, PAGE, next)
      .then((p) => {
        setItems((xs) => [...(xs ?? []), ...p.items]);
        setNext(p.nextOffset);
      })
      .catch(fail(setError))
      .finally(() => setBusy(false));
  };

  const pair =
    items !== null && picked.length === 2
      ? comparePair(items, picked[0] as string, picked[1] as string)
      : null;

  const show = (c: { base: string; head: string } | null) =>
    setParams(
      (ps) => {
        const out = new URLSearchParams(ps);
        if (c === null) {
          out.delete("base");
          out.delete("head");
        } else {
          out.set("base", c.base);
          out.set("head", c.head);
        }
        return out;
      },
      { replace: false },
    );

  return (
    <section aria-labelledby="rubric-history-h">
      <h2 id="rubric-history-h">History</h2>
      <p className="mute small-text">
        The commits that changed this rubric, newest first. Pick two to see what changed between
        them.
      </p>
      {error !== null && (
        <p className="error" role="alert">
          {error}
        </p>
      )}
      {items === null ? (
        error === null && <p className="mute">Loading the history…</p>
      ) : items.length === 0 ? (
        <p className="mute">No commits have changed this rubric.</p>
      ) : (
        <div className="table-scroll">
          <table>
            <thead>
              <tr>
                <th scope="col">
                  <span className="sr-only">Compare</span>
                </th>
                <th scope="col">Commit</th>
                <th scope="col">Message</th>
                <th scope="col">Author</th>
                <th scope="col">Date</th>
              </tr>
            </thead>
            <tbody>
              {items.map((c) => (
                <tr key={c.sha} className={picked.includes(c.sha) ? "picked" : ""}>
                  <td>
                    <input
                      type="checkbox"
                      checked={picked.includes(c.sha)}
                      aria-label={`Compare ${shortSha(c.sha)}`}
                      onChange={() => setPicked((ps) => togglePick(ps, c.sha))}
                    />
                  </td>
                  <td>
                    <CommitLink owner={owner} name={name} sha={c.sha} />
                    {c.sha === inUse && <span className="tag">in use</span>}
                    {c.legacyVersion !== null && (
                      <span className="tag" title="Exported from this version of the platform">
                        v{c.legacyVersion}
                      </span>
                    )}
                  </td>
                  <td className="body">
                    <GitHubLink href={c.url}>{commitTitle(c.message)}</GitHubLink>
                  </td>
                  <td>
                    {c.author}
                    {c.authorLogin !== null && <span className="mute data"> @{c.authorLogin}</span>}
                  </td>
                  <td className="data mute">{c.date}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <div className="actions">
        <button type="button" onClick={() => show(pair)} disabled={pair === null}>
          {pair === null
            ? "Compare two commits"
            : `Compare ${shortSha(pair.base)} with ${shortSha(pair.head)}`}
        </button>
        {next !== null && (
          <button type="button" className="ghost" onClick={more} disabled={busy}>
            Load older commits
          </button>
        )}
      </div>
      {compareError !== null && (
        <p className="error" role="alert">
          {compareError}
        </p>
      )}
      {compare !== null && (
        <section className="notice viewed" aria-labelledby="compare-h">
          <h3 id="compare-h" tabIndex={-1}>
            From <span className="data">{shortSha(compare.base)}</span> to{" "}
            <span className="data">{shortSha(compare.head)}</span>
            {compare.diff !== null && `: ${diffCounts(compare.diff)}`}
          </h3>
          <p className="small-text">
            <GitHubLink href={compare.url}>The comparison on GitHub</GitHubLink>
          </p>
          {compare.diffError !== null && (
            <p className="error">
              No diff: <span className="body">{compare.diffError}</span>
            </p>
          )}
          {compare.diff !== null && (
            <>
              <ProposalDiffView diff={compare.diff} subject="The commits change" />
              {compare.diff.styleNotes !== null && (
                <div className="change">
                  <h4>Style notes</h4>
                  <StyleNotesDiff change={compare.diff.styleNotes} />
                </div>
              )}
            </>
          )}
          <div className="actions">
            <button type="button" className="ghost" onClick={() => show(null)}>
              Close
            </button>
          </div>
        </section>
      )}
    </section>
  );
}