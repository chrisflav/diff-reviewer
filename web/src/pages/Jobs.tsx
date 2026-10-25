import { useCallback, useState, type FormEvent } from "react";
import { Link, useSearchParams } from "react-router-dom";
import { api, UnauthorizedError, type Job, type JobKind, type Repo } from "../api";
import { countSeverity } from "../review";
import { useLoad } from "../useLoad";

export function JobsPage({ onUnauthorized }: { onUnauthorized: () => void }) {
  const [params, setParams] = useSearchParams();
  const kind = kindOf(params.get("kind"));
  const fetchAll = useCallback(() => Promise.all([api.jobs(kind), api.repos()]), [kind]);
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

      <fieldset className="kind-filter">
        <legend>Show</legend>
        {kinds.map((k) => (
          <label key={k.value} className="check">
            <input
              type="radio"
              name="kind"
              checked={kind === k.value}
              onChange={() =>
                setParams(
                  (p) => {
                    const n = new URLSearchParams(p);
                    if (k.value === "review") n.delete("kind");
                    else n.set("kind", k.value);
                    return n;
                  },
                  { replace: true },
                )
              }
            />
            {k.label}
          </label>
        ))}
      </fieldset>

      {data === null ? (
        <p className="mute">Loading…</p>
      ) : jobs.length === 0 ? (
        <p className="mute">
          {kind === "calibration" ? "No calibration jobs yet." : "No reviews yet."}
        </p>
      ) : (
        <div className="table-scroll">
          <table>
            <thead>
              <tr>
                <th>Pull request</th>
                {kind !== "review" && <th>Kind</th>}
                <th>Status</th>
                <th>Type</th>
                <th>Comments</th>
                <th>
                  Blocker<span className="sr-only">s</span> / major
                </th>
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
                  {kind !== "review" && (
                    <td>
                      <span className={`tag kind-${j.kind ?? "review"}`}>{j.kind ?? "review"}</span>
                    </td>
                  )}
                  <td>
                    <span className={`status s-${j.status}`}>{j.status}</span>
                  </td>
                  <td>{j.prType ?? <span className="mute">—</span>}</td>
                  <td className="data">{j.review?.comments.length ?? "—"}</td>
                  <td className="data">
                    {j.review === null ? (
                      "—"
                    ) : (
                      <SeverityCounts
                        blocker={countSeverity(j.review, "blocker")}
                        major={countSeverity(j.review, "major")}
                      />
                    )}
                  </td>
                  <td className="data mute">{j.updatedAt}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </>
  );
}

const kinds: { value: JobKind | "all"; label: string }[] = [
  { value: "review", label: "Reviews" },
  { value: "calibration", label: "Calibration jobs (never posted)" },
  { value: "all", label: "All" },
];

/** The kind of jobs `?kind=` asks for: reviews unless it names another. */
function kindOf(k: string | null): JobKind | "all" {
  return k === "calibration" || k === "all" ? k : "review";
}

/** How many blockers and majors a review carries, said in words as well as numbers. */
function SeverityCounts({ blocker, major }: { blocker: number; major: number }) {
  return (
    <span className={blocker > 0 ? "counts-sev has-blocker" : "counts-sev"}>
      <span aria-hidden="true">
        {blocker} / {major}
      </span>
      <span className="sr-only">
        {blocker} {blocker === 1 ? "blocker" : "blockers"}, {major} major
      </span>
    </span>
  );
}