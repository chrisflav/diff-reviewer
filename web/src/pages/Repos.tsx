import { useEffect, useState, type FormEvent } from "react";
import { Link } from "react-router-dom";
import { api, ApiError, UnauthorizedError, type PostingMode, type Repo } from "../api";
import { formOf, onlyAutoReviewChanged, putBody, registerBody } from "../repoSettings";
import { rubricStashKey } from "../stash";
import { useLoad } from "../useLoad";
import { repoPath } from "./Calibration";

export function ReposPage({ onUnauthorized }: { onUnauthorized: () => void }) {
  const { data: repos, error, reload, setError } = useLoad(api.repos, onUnauthorized);
  const [slug, setSlug] = useState("");
  const [mode, setMode] = useState<PostingMode>("staged");
  const [autoReview, setAutoReview] = useState(false);
  const [toggleError, setToggleError] = useState<string | null>(null);

  const fail = (err: unknown) => {
    if (err instanceof UnauthorizedError) onUnauthorized();
    else setError(err instanceof Error ? err.message : String(err));
  };

  const submit = (e: FormEvent) => {
    e.preventDefault();
    const [owner, name, ...rest] = slug.trim().split("/");
    if (owner === undefined || name === undefined || rest.length > 0) {
      setError("Name the repository as owner/name.");
      return;
    }
    // Registering one listed already writes over the version listed, keeping what this form
    // does not set; one registered meanwhile is a 409, not overwritten.
    const listed = (repos ?? []).find(
      (r) => rubricStashKey(r.owner, r.name) === rubricStashKey(owner, name),
    );
    const body =
      listed === undefined
        ? registerBody(mode, autoReview)
        : putBody(listed, { ...formOf(listed), mode, autoReview });
    api
      .putRepoSettings(owner, name, body)
      .then(() => {
        setSlug("");
        reload();
      })
      .catch((err: unknown) => {
        if (err instanceof ApiError && err.status === 409) {
          setError(
            `${owner}/${name} was registered or changed elsewhere since this page loaded it, so nothing was written: ${err.message}. The list is reloaded; register again to write over it.`,
          );
          reload();
        } else fail(err);
      });
  };

  return (
    <>
      <h1>Repositories</h1>
      {error !== null && <p className="error">{error}</p>}
      {toggleError !== null && (
        <p className="notice warn-notice" role="alert">
          {toggleError}
        </p>
      )}
      <form className="inline" onSubmit={submit}>
        <input
          aria-label="Repository"
          placeholder="owner/name"
          className="data"
          value={slug}
          onChange={(e) => setSlug(e.target.value)}
        />
        <select
          aria-label="Posting mode"
          value={mode}
          onChange={(e) => setMode(e.target.value as PostingMode)}
        >
          <option value="staged">staged — approve before posting</option>
          <option value="direct">direct — post as submitted</option>
        </select>
        <label className="check">
          <input
            type="checkbox"
            checked={autoReview}
            onChange={(e) => setAutoReview(e.target.checked)}
          />
          Review open pull requests on its own
        </label>
        <button type="submit" disabled={slug.trim() === ""}>
          Register
        </button>
      </form>

      {repos === null ? (
        <p className="mute">Loading…</p>
      ) : repos.length === 0 ? (
        <p className="mute">No repositories yet.</p>
      ) : (
        <div className="table-scroll">
          <table>
            <thead>
              <tr>
                <th>Repository</th>
                <th>Posting</th>
                <th>Automatic</th>
                <th>Trusted reviewers</th>
                <th>Pages</th>
                <th>Registered</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {repos.map((r) => (
                <tr key={`${r.owner}/${r.name}`}>
                  <td className="data">
                    {r.owner}/{r.name}
                  </td>
                  <td>{r.mode}</td>
                  <td>
                    <AutoReviewToggle
                      repo={r}
                      onChanged={() => {
                        setToggleError(null);
                        reload();
                      }}
                      onError={(err) => {
                        if (err instanceof ApiError && err.status === 409) {
                          // Shown apart from the list's own error, which a reload clears.
                          setToggleError(err.message);
                          reload();
                        } else fail(err);
                      }}
                    />
                  </td>
                  <td className="data">{(r.trustedReviewers ?? []).length}</td>
                  <td>
                    <span className="links">
                      <Link
                        to={repoPath(r.owner, r.name)}
                        aria-label={`Settings of ${r.owner}/${r.name}`}
                      >
                        Settings
                      </Link>
                      <Link
                        to={`${repoPath(r.owner, r.name)}/rubric`}
                        aria-label={`Rubric of ${r.owner}/${r.name}`}
                      >
                        Rubric
                      </Link>
                      <Link
                        to={`${repoPath(r.owner, r.name)}/calibration`}
                        aria-label={`Calibration of ${r.owner}/${r.name}`}
                      >
                        Calibration
                      </Link>
                    </span>
                  </td>
                  <td className="data mute">{r.createdAt}</td>
                  <td className="right">
                    <button
                      className="ghost"
                      onClick={() => {
                        if (
                          window.confirm(`Unregister ${r.owner}/${r.name}? Its reviews are kept.`)
                        )
                          api.deleteRepo(r.owner, r.name).then(reload).catch(fail);
                      }}
                    >
                      Unregister
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </>
  );
}

/** Turns finding the repository's open pull requests on or off, keeping its posting mode. */
function AutoReviewToggle({
  repo,
  onChanged,
  onError,
}: {
  repo: Repo;
  onChanged: () => void;
  onError: (err: unknown) => void;
}) {
  // What was asked for, shown until the server's answer replaces it (or, refused, drops it).
  const [asked, setAsked] = useState<boolean | null>(null);
  const on = asked ?? repo.autoReview;
  useEffect(() => setAsked(null), [repo]);
  return (
    <label className="check">
      <input
        type="checkbox"
        checked={on}
        disabled={asked !== null}
        onChange={(e) => {
          const want = e.target.checked;
          setAsked(want);
          toggleAutoReview(repo, want)
            .then(onChanged)
            .catch((err: unknown) => {
              setAsked(null);
              onError(err);
            });
        }}
      />
      <span className="sr-only">
        Review open pull requests of {repo.owner}/{repo.name} on its own
      </span>
      {on ? "on" : "off"}
    </label>
  );
}

/**
 * Turn `autoReview` to `want`, over the version listed. A 409 means the settings changed
 * elsewhere: they are read again. When only `autoReview` changed, the toggle is written over the
 * new version (or not at all, when the other change already set it to `want`). When anything else
 * changed (the mode, the trusted reviewers, a setting this version does not know), nothing is
 * written: turning automatic reviews on may not be what the person wants of the settings as they
 * are now, say in a repository that became `direct`. The 409 is reported, and the list reloaded.
 */
async function toggleAutoReview(repo: Repo, want: boolean): Promise<void> {
  try {
    await api.putRepoSettings(
      repo.owner,
      repo.name,
      putBody(repo, { ...formOf(repo), autoReview: want }),
    );
  } catch (err) {
    if (!(err instanceof ApiError && err.status === 409)) throw err;
    const key = rubricStashKey(repo.owner, repo.name);
    const now = (await api.repos()).find((r) => rubricStashKey(r.owner, r.name) === key);
    if (now === undefined) throw new ApiError(404, `${repo.owner}/${repo.name} is not registered`);
    if (!onlyAutoReviewChanged(repo, now))
      throw new ApiError(
        409,
        `The settings of ${repo.owner}/${repo.name} changed elsewhere since this page loaded them (now version ${now.version}), so automatic reviews were not turned ${want ? "on" : "off"}. The list is reloaded; look at the settings and try again.`,
      );
    if (now.autoReview === want) return;
    await api.putRepoSettings(
      now.owner,
      now.name,
      putBody(now, { ...formOf(now), autoReview: want }),
    );
  }
}