import { useCallback, useState, type FormEvent } from "react";
import { Link } from "react-router-dom";
import { api, UnauthorizedError, type Job, type Repo } from "../api";
import { useLoad } from "../useLoad";

export function JobsPage({ onUnauthorized }: { onUnauthorized: () => void }) {
  const fetchAll = useCallback(
    () => Promise.all([api.jobs(), api.repos()]),
    [],
  );
  const { data, error, reload, setError } = useLoad(fetchAll, onUnauthorized);
  const [repo, setRepo] = useState("");
  const [pr, setPr] = useState("");
  const [sha, setSha] = useState("");

  const jobs: Job[] = data?.[0] ?? [];
  const repos: Repo[] = data?.[1] ?? [];

  const submit = (e: FormEvent) => {
    e.preventDefault();
    const [owner, name] = repo.split("/");
    const prNumber = Number(pr);
    if (owner === undefined || name === undefined) return;
    if (!Number.isInteger(prNumber) || prNumber < 1 || prNumber > 2147483647) {
      setError("That is not a pull request number.");
      return;
    }
    api
      .createJob(owner, name, prNumber, sha.trim() === "" ? null : sha.trim())
      .then(() => {
        setPr("");
        setSha("");
        reload();
      })
      .catch((err: unknown) => {
        if (err instanceof UnauthorizedError) onUnauthorized();
        else setError(err instanceof Error ? err.message : String(err));
      });
  };

  return (
    <>
      <h1>Reviews</h1>
      {error !== null && <p className="error">{error}</p>}

      <form className="inline" onSubmit={submit}>
        <select value={repo} onChange={(e) => setRepo(e.target.value)} aria-label="Repository">
          <option value="">Repository…</option>
          {repos.map((r) => (
            <option key={`${r.owner}/${r.name}`} value={`${r.owner}/${r.name}`}>
              {r.owner}/{r.name}
            </option>
          ))}
        </select>
        <input
          aria-label="Pull request number"
          placeholder="PR #"
          inputMode="numeric"
          value={pr}
          onChange={(e) => setPr(e.target.value.replace(/[^0-9]/g, ""))}
        />
        <input
          aria-label="Head commit"
          placeholder="head commit (optional)"
          className="data"
          value={sha}
          onChange={(e) => setSha(e.target.value)}
        />
        <button type="submit" disabled={repo === "" || pr === ""}>
          Request review
        </button>
      </form>
      {repos.length === 0 && data !== null && (
        <p className="mute">
          Register a repository on the <Link to="/repos">Repositories</Link> page first.
        </p>
      )}

      {data === null ? (
        <p className="mute">Loading…</p>
      ) : jobs.length === 0 ? (
        <p className="mute">No reviews yet.</p>
      ) : (
        <table>
          <thead>
            <tr>
              <th>Pull request</th>
              <th>Status</th>
              <th>Comments</th>
              <th>Updated</th>
            </tr>
          </thead>
          <tbody>
            {jobs.map((j) => (
              <tr key={j.id}>
                <td>
                  <Link to={`/jobs/${j.id}`}>
                    {j.owner}/{j.name}#{j.prNumber}
                  </Link>
                </td>
                <td>
                  <span className={`status s-${j.status}`}>{j.status}</span>
                </td>
                <td className="data">{j.review?.comments.length ?? "—"}</td>
                <td className="data mute">{j.updatedAt}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </>
  );
}