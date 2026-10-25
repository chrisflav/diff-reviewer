import { useEffect, useState, type FormEvent } from "react";
import { Link } from "react-router-dom";
import { api, UnauthorizedError, type PostingMode, type Repo } from "../api";
import { useLoad } from "../useLoad";

export function ReposPage({ onUnauthorized }: { onUnauthorized: () => void }) {
  const { data: repos, error, reload, setError } = useLoad(api.repos, onUnauthorized);
  const [slug, setSlug] = useState("");
  const [mode, setMode] = useState<PostingMode>("staged");
  const [autoReview, setAutoReview] = useState(false);

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
    api
      .putRepo(owner, name, mode, autoReview)
      .then(() => {
        setSlug("");
        reload();
      })
      .catch(fail);
  };

  return (
    <>
      <h1>Repositories</h1>
      {error !== null && <p className="error">{error}</p>}
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
                <th>Rubric</th>
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
                    <AutoReviewToggle repo={r} onChanged={reload} onError={fail} />
                  </td>
                  <td>
                    <Link
                      to={`/repos/${encodeURIComponent(r.owner)}/${encodeURIComponent(r.name)}/rubric`}
                      aria-label={`Rubric of ${r.owner}/${r.name}`}
                    >
                      Rubric
                    </Link>
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
          setAsked(e.target.checked);
          api
            .putRepo(repo.owner, repo.name, repo.mode, e.target.checked)
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