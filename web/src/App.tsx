import { useCallback, useContext, useEffect, useRef, useState, type FormEvent } from "react";
import { createBrowserRouter, NavLink, Outlet, RouterProvider } from "react-router-dom";
import { api, ApiError, NetworkError, UnauthorizedError } from "./api";
import { JobsPage } from "./pages/Jobs";
import { JobPage } from "./pages/Job";
import { ReposPage } from "./pages/Repos";
import { UnsavedContext } from "./unsaved";

type AuthState = "checking" | "unreachable" | "signedOut" | "signedIn";

export function App() {
  const [auth, setAuth] = useState<AuthState>("checking");

  useEffect(() => {
    api
      .session()
      .then((s) => setAuth(s.authenticated ? "signedIn" : "signedOut"))
      .catch((err: unknown) => setAuth(err instanceof NetworkError ? "unreachable" : "signedOut"));
  }, []);

  // Any page that meets a 401 sends the person back to the login screen.
  const onUnauthorized = useCallback(() => setAuth("signedOut"), []);

  if (auth === "checking") return <div className="center mute">…</div>;
  if (auth === "unreachable")
    return <div className="center error">The server could not be reached. Reload to try again.</div>;
  if (auth === "signedOut") return <Login onSignedIn={() => setAuth("signedIn")} />;

  return <SignedIn onUnauthorized={onUnauthorized} onSignedOut={() => setAuth("signedOut")} />;
}

function SignedIn({
  onUnauthorized,
  onSignedOut,
}: {
  onUnauthorized: () => void;
  onSignedOut: () => void;
}) {
  const unsaved = useRef(false);
  // A data router, made once: it is what lets a page with unsaved edits hold up a navigation.
  const [router] = useState(() =>
    createBrowserRouter([
      {
        element: <Layout onSignedOut={onSignedOut} />,
        children: [
          { path: "/", element: <JobsPage onUnauthorized={onUnauthorized} /> },
          { path: "/jobs/:id", element: <JobPage onUnauthorized={onUnauthorized} /> },
          { path: "/repos", element: <ReposPage onUnauthorized={onUnauthorized} /> },
          { path: "*", element: <p className="mute">Nothing here.</p> },
        ],
      },
    ]),
  );
  return (
    <UnsavedContext.Provider value={unsaved}>
      <RouterProvider router={router} />
    </UnsavedContext.Provider>
  );
}

function Layout({ onSignedOut }: { onSignedOut: () => void }) {
  const unsaved = useContext(UnsavedContext);
  return (
    <>
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
            // The edits stay in this tab's storage, and the page offers them back on return.
            if (
              unsaved.current &&
              !window.confirm(
                "This review has unsaved edits. Sign out anyway? They are kept in this tab and offered back when you sign in again here.",
              )
            )
              return;
            void api.logout().finally(onSignedOut);
          }}
        >
          Sign out
        </button>
      </header>
      <main>
        <Outlet />
      </main>
    </>
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