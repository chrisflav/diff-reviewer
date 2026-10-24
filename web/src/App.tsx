import { useCallback, useEffect, useState, type FormEvent } from "react";
import { BrowserRouter, NavLink, Route, Routes } from "react-router-dom";
import { api, ApiError, UnauthorizedError } from "./api";
import { JobsPage } from "./pages/Jobs";
import { JobPage } from "./pages/Job";
import { ReposPage } from "./pages/Repos";

type AuthState = "checking" | "signedOut" | "signedIn";

export function App() {
  const [auth, setAuth] = useState<AuthState>("checking");

  useEffect(() => {
    api
      .session()
      .then((s) => setAuth(s.authenticated ? "signedIn" : "signedOut"))
      .catch(() => setAuth("signedOut"));
  }, []);

  // Any page that meets a 401 sends the person back to the login screen.
  const onUnauthorized = useCallback(() => setAuth("signedOut"), []);

  if (auth === "checking") return <div className="center mute">…</div>;
  if (auth === "signedOut") return <Login onSignedIn={() => setAuth("signedIn")} />;

  return (
    <BrowserRouter>
      <header className="bar">
        <span className="wordmark">diff-reviewer</span>
        <nav>
          <NavLink to="/" end>
            Reviews
          </NavLink>
          <NavLink to="/repos">Repositories</NavLink>
        </nav>
        <button
          className="ghost"
          onClick={() => {
            void api.logout().finally(() => setAuth("signedOut"));
          }}
        >
          Sign out
        </button>
      </header>
      <main>
        <Routes>
          <Route path="/" element={<JobsPage onUnauthorized={onUnauthorized} />} />
          <Route path="/jobs/:id" element={<JobPage onUnauthorized={onUnauthorized} />} />
          <Route path="/repos" element={<ReposPage onUnauthorized={onUnauthorized} />} />
          <Route path="*" element={<p className="mute">Nothing here.</p>} />
        </Routes>
      </main>
    </BrowserRouter>
  );
}

function Login({ onSignedIn }: { onSignedIn: () => void }) {
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);

  const submit = (e: FormEvent) => {
    e.preventDefault();
    setError(null);
    api
      .login(password)
      .then(onSignedIn)
      .catch((err: unknown) => {
        if (err instanceof UnauthorizedError) setError("That is not the password.");
        else if (err instanceof ApiError) setError(err.message);
        else setError("The server could not be reached.");
      });
  };

  return (
    <form className="login" onSubmit={submit}>
      <h1 className="wordmark">diff-reviewer</h1>
      <label>
        Password
        <input
          type="password"
          autoFocus
          autoComplete="current-password"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
        />
      </label>
      {error !== null && <p className="error">{error}</p>}
      <button type="submit" disabled={password === ""}>
        Sign in
      </button>
    </form>
  );
}