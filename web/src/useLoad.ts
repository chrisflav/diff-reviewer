import { useCallback, useEffect, useRef, useState } from "react";
import { UnauthorizedError } from "./api";

/** Load `fetcher` on mount and on `reload`, reporting a 401 to `onUnauthorized`. */
export function useLoad<T>(fetcher: () => Promise<T>, onUnauthorized: () => void) {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<string | null>(null);
  // Only the latest request may land: a slow answer for the page one just left must not
  // overwrite the one for the page one is on.
  const latest = useRef(0);

  const reload = useCallback(() => {
    const ticket = ++latest.current;
    fetcher()
      .then((d) => {
        if (ticket !== latest.current) return;
        setData(d);
        setError(null);
      })
      .catch((err: unknown) => {
        if (ticket !== latest.current) return;
        if (err instanceof UnauthorizedError) onUnauthorized();
        else setError(err instanceof Error ? err.message : String(err));
      });
  }, [fetcher, onUnauthorized]);

  useEffect(reload, [reload]);

  // For a write that answers with the new value: showing it at once beats a reload, which would
  // first show the old one again. A load still in flight is older, and is dropped.
  const replace = useCallback((d: T) => {
    latest.current++;
    setData(d);
    setError(null);
  }, []);

  return { data, error, reload, setError, setData: replace };
}