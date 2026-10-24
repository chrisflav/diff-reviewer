import { useState, type FormEvent } from "react";
import { api, UnauthorizedError, type PostingMode } from "../api";
import { useLoad } from "../useLoad";

export function ReposPage({ onUnauthorized }: { onUnauthorized: () => void }) {
  const { data: repos, error, reload, setError } = useLoad(api.repos, onUnauthorized);
  const [slug, setSlug] = useState("");
  const [mode, setMode] = useState<PostingMode>("staged");

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
      .putRepo(owner, name, mode)
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
        <button type="submit" disabled={slug.trim() === ""}>
          Register
        </button>
      </form>

      {repos === null ? (
        <p className="mute">Loading…</p>
      ) : repos.length === 0 ? (
        <p className="mute">No repositories yet.</p>
      ) : (
        <table>
          <thead>
            <tr>
              <th>Repository</th>
              <th>Posting</th>
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
                <td className="data mute">{r.createdAt}</td>
                <td className="right">
                  <button
                    className="ghost"
                    onClick={() => {
                      if (window.confirm(`Unregister ${r.owner}/${r.name}? Its reviews are kept.`))
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
      )}
    </>
  );
}