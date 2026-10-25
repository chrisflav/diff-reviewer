import { useCallback, useContext, useEffect, useRef, useState, type FormEvent } from "react";
import { createBrowserRouter, NavLink, Outlet, RouterProvider } from "react-router-dom";
import { api, ApiError, NetworkError, UnauthorizedError } from "./api";
import { CalibrationPage } from "./pages/Calibration";
import { CalibrationRunPage } from "./pages/CalibrationRun";
import { CalibrationSamplePage } from "./pages/CalibrationSample";
import { JobsPage } from "./pages/Jobs";
import { JobPage } from "./pages/Job";
import { ProposalPage, ProposalsPage } from "./pages/Proposals";
import { RepoSettingsPage } from "./pages/RepoSettings";
import { ReposPage } from "./pages/Repos";
import { RubricPage } from "./pages/Rubric";
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
    return (
      <div className="center error">The server could not be reached. Reload to try again.</div>
    );
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
          {
            path: "/repos/:owner/:name/rubric",
            element: <RubricPage onUnauthorized={onUnauthorized} />,
          },
          {
            path: "/repos/:owner/:name",
            element: <RepoSettingsPage onUnauthorized={onUnauthorized} />,
          },
          {
            path: "/repos/:owner/:name/calibration",
            element: <CalibrationPage onUnauthorized={onUnauthorized} />,
          },
          {
            path: "/repos/:owner/:name/calibration/runs/:id",
            element: <CalibrationRunPage onUnauthorized={onUnauthorized} />,
          },
          {
            path: "/repos/:owner/:name/calibration/samples/:id",
            element: <CalibrationSamplePage onUnauthorized={onUnauthorized} />,
          },
          {
            path: "/repos/:owner/:name/proposals",
            element: <ProposalsPage onUnauthorized={onUnauthorized} />,
          },
          {
            path: "/repos/:owner/:name/proposals/:id",
            element: <ProposalPage onUnauthorized={onUnauthorized} />,
          },
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
  // The API token signs in too, and no limit refuses it: the way in while password attempts are.
  const [withToken, setWithToken] = useState(false);
  const [secret, setSecret] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [limited, setLimited] = useState(false);

  const submit = (e: FormEvent) => {
    e.preventDefault();
    setError(null);
    (withToken ? api.loginWithToken(secret) : api.login(secret))
      .then(onSignedIn)
      .catch((err: unknown) => {
        if (err instanceof UnauthorizedError)
          setError(withToken ? "That is not the API token." : "That is not the password.");
        else if (err instanceof ApiError) {
          if (err.status === 429 && !withToken) {
            setLimited(true);
            setError(`${err.message}. The API token signs in meanwhile.`);
          } else setError(err.message);
        } else setError("The server could not be reached.");
      });
  };

  const switchTo = (token: boolean) => {
    setWithToken(token);
    setSecret("");
    setError(null);
  };

  return (
    <form className="login" onSubmit={submit}>
      <h1 className="wordmark">diff-reviewer</h1>
      <label>
        {withToken ? "API token" : "Password"}
        <input
          key={withToken ? "token" : "password"}
          type="password"
          className={withToken ? "data" : ""}
          autoFocus
          autoComplete={withToken ? "off" : "current-password"}
          value={secret}
          onChange={(e) => setSecret(e.target.value)}
        />
      </label>
      {error !== null && (
        <p className="error" role="alert">
          {error}
        </p>
      )}
      <button type="submit" disabled={secret === ""}>
        Sign in
      </button>
      <button
        type="button"
        className={limited && !withToken ? "" : "ghost"}
        onClick={() => switchTo(!withToken)}
      >
        {withToken ? "Sign in with the password" : "Sign in with API token"}
      </button>
    </form>
  );
}