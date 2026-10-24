import { useCallback, useEffect, useState } from "react";
import { UnauthorizedError } from "./api";

/** Load `fetcher` on mount and on `reload`, reporting a 401 to `onUnauthorized`. */
export function useLoad<T>(fetcher: () => Promise<T>, onUnauthorized: () => void) {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<string | null>(null);

  const reload = useCallback(() => {
    fetcher()
      .then((d) => {
        setData(d);
        setError(null);
      })
      .catch((err: unknown) => {
        if (err instanceof UnauthorizedError) onUnauthorized();
        else setError(err instanceof Error ? err.message : String(err));
      });
  }, [fetcher, onUnauthorized]);

  useEffect(reload, [reload]);

  return { data, error, reload, setError };
}