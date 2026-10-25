import { useEffect, useId, useRef, useState } from "react";
import type { CalibrationRun } from "../api";
import { formatRatio } from "../calibration";
import { Ratio } from "./Ratio";

/** One run's point on the chart: precision and recall, null where there was nothing to divide. */
export interface RunPoint {
  id: string;
  createdAt: string;
  precision: number | null;
  recall: number | null;
  matched: number;
  agentComments: number;
  humanComments: number;
}

/** The runs as points, oldest first: the order a chart over time reads in. */
export function runPoints(runs: CalibrationRun[]): RunPoint[] {
  return [...runs]
    .sort((a, b) => (a.createdAt < b.createdAt ? -1 : a.createdAt > b.createdAt ? 1 : 0))
    .map((r) => ({
      id: r.id,
      createdAt: r.createdAt,
      precision: r.aggregate.agentComments === 0 ? null : r.aggregate.precision,
      recall: r.aggregate.humanComments === 0 ? null : r.aggregate.recall,
      matched: r.aggregate.matched,
      agentComments: r.aggregate.agentComments,
      humanComments: r.aggregate.humanComments,
    }));
}

/** The label at a series' last point: its ratio, from the run's own counts. */
export function directLabel(p: RunPoint, k: "precision" | "recall"): string {
  const den = k === "precision" ? p.agentComments : p.humanComments;
  return `${k} ${formatRatio(p.matched, den, p[k]).percent}`;
}

/** The widest the chart is drawn; narrower, it is drawn at the width it has, so text stays legible. */
const MAX_W = 720;
const MIN_W = 280;
const H = 220;
const PAD = { left: 44, right: 104, top: 12, bottom: 28 };

/**
 * Precision and recall per run over time: inline SVG, no script but React's, so the page's CSP
 * holds. Precision is a solid line with round points, recall a dashed line with square ones, each
 * labelled at its last point, so that neither is told by its colour alone; a table beside it says
 * the same, with the denominators.
 */
export function RunChart({ runs, stale }: { runs: CalibrationRun[]; stale: boolean }) {
  const pts = runPoints(runs);
  const titleId = useId();
  const descId = useId();
  const [hover, setHover] = useState<number | null>(null);
  // Drawn at the width it is shown at, one unit a pixel: scaled down instead, its text would shrink
  // past reading at phone width.
  const box = useRef<HTMLElement>(null);
  const [W, setW] = useState(640);
  useEffect(() => {
    const el = box.current;
    if (el === null || typeof ResizeObserver === "undefined") return;
    const fit = () => setW(Math.max(MIN_W, Math.min(MAX_W, Math.floor(el.clientWidth))));
    fit();
    const o = new ResizeObserver(fit);
    o.observe(el);
    return () => o.disconnect();
  }, []);
  if (pts.length === 0) return null;
  const iw = W - PAD.left - PAD.right;
  const ih = H - PAD.top - PAD.bottom;
  const x = (i: number) => PAD.left + (pts.length === 1 ? iw / 2 : (i * iw) / (pts.length - 1));
  const y = (v: number) => PAD.top + ih - v * ih;
  const path = (k: "precision" | "recall") => {
    let d = "";
    let pen = false;
    pts.forEach((p, i) => {
      const v = p[k];
      if (v === null) {
        pen = false;
        return;
      }
      d += `${pen ? "L" : "M"}${x(i).toFixed(1)},${y(v).toFixed(1)}`;
      pen = true;
    });
    return d;
  };
  const last = (k: "precision" | "recall") => {
    for (let i = pts.length - 1; i >= 0; i--) {
      const v = pts[i]?.[k];
      if (v !== null && v !== undefined) return { i, v };
    }
    return null;
  };
  const lp = last("precision");
  const lr = last("recall");
  // Direct labels that would overlap are moved apart.
  let lpY = lp === null ? 0 : y(lp.v);
  let lrY = lr === null ? 0 : y(lr.v);
  if (lp !== null && lr !== null && Math.abs(lpY - lrY) < 14) {
    const mid = (lpY + lrY) / 2;
    if (lp.v >= lr.v) {
      lpY = mid - 7;
      lrY = mid + 7;
    } else {
      lpY = mid + 7;
      lrY = mid - 7;
    }
  }
  const h = hover === null ? null : (pts[hover] ?? null);
  const step = pts.length > 1 ? iw / (pts.length - 1) : iw;

  return (
    <figure className="run-chart" ref={box}>
      <div className="legend" aria-hidden="true">
        <span className="key key-precision">
          <svg width="28" height="10" viewBox="0 0 28 10">
            <line x1="0" y1="5" x2="28" y2="5" className="line-precision" />
            <circle cx="14" cy="5" r="4" className="pt-precision" />
          </svg>
          precision
        </span>
        <span className="key key-recall">
          <svg width="28" height="10" viewBox="0 0 28 10">
            <line x1="0" y1="5" x2="28" y2="5" className="line-recall" />
            <rect x="10" y="1" width="8" height="8" className="pt-recall" />
          </svg>
          recall
        </span>
      </div>
      <svg
        viewBox={`0 0 ${W} ${H}`}
        className="chart"
        role="img"
        aria-labelledby={titleId}
        aria-describedby={descId}
        onMouseLeave={() => setHover(null)}
      >
        <title id={titleId}>Precision and recall per run, oldest run first</title>
        <desc id={descId}>
          {pts.length} {pts.length === 1 ? "run" : "runs"}, in the order they were started, evenly
          spaced. The table below gives every value with its denominator.
        </desc>
        {[0, 0.25, 0.5, 0.75, 1].map((t) => (
          <g key={t}>
            <line x1={PAD.left} x2={W - PAD.right} y1={y(t)} y2={y(t)} className="grid" />
            <text x={PAD.left - 6} y={y(t) + 4} className="axis" textAnchor="end">
              {Math.round(t * 100)}%
            </text>
          </g>
        ))}
        <text x={PAD.left} y={H - 8} className="axis">
          first run
        </text>
        <text x={W - PAD.right} y={H - 8} className="axis" textAnchor="end">
          last run
        </text>
        {hover !== null && (
          <line x1={x(hover)} x2={x(hover)} y1={PAD.top} y2={PAD.top + ih} className="cross" />
        )}
        <path d={path("precision")} className="line-precision" />
        <path d={path("recall")} className="line-recall" />
        {pts.map((p, i) => (
          <g key={p.id}>
            {p.precision !== null && (
              <circle cx={x(i)} cy={y(p.precision)} r={4} className="pt-precision" />
            )}
            {p.recall !== null && (
              <rect x={x(i) - 4} y={y(p.recall) - 4} width={8} height={8} className="pt-recall" />
            )}
            <rect
              x={x(i) - step / 2}
              y={PAD.top}
              width={step}
              height={ih}
              className="hit"
              onMouseEnter={() => setHover(i)}
            />
          </g>
        ))}
        {lp !== null && (
          <text x={x(lp.i) + 8} y={lpY + 4} className="direct">
            {directLabel(pts[lp.i] as RunPoint, "precision")}
          </text>
        )}
        {lr !== null && (
          <text x={x(lr.i) + 8} y={lrY + 4} className="direct">
            {directLabel(pts[lr.i] as RunPoint, "recall")}
          </text>
        )}
      </svg>
      <figcaption className="mute small-text">
        The runs on this page of the list, oldest first, one step apart whatever the time between
        them. Stale scores are {stale ? "counted" : "left out"}.
      </figcaption>
      <p className="chart-tip small-text" aria-live="polite">
        {h === null ? (
          <span className="mute">Point at a run for its figures.</span>
        ) : (
          <>
            <span className="data">{h.createdAt}</span>: precision{" "}
            <Ratio num={h.matched} den={h.agentComments} value={h.precision} />, recall{" "}
            <Ratio num={h.matched} den={h.humanComments} value={h.recall} />
          </>
        )}
      </p>
      <details className="chart-table">
        <summary>The chart as a table</summary>
        <div className="table-scroll">
          <table>
            <thead>
              <tr>
                <th scope="col">Run</th>
                <th scope="col">Started</th>
                <th scope="col">Precision</th>
                <th scope="col">Recall</th>
              </tr>
            </thead>
            <tbody>
              {pts.map((p) => (
                <tr key={p.id}>
                  <td className="data">{p.id}</td>
                  <td className="data mute">{p.createdAt}</td>
                  <td>
                    <Ratio num={p.matched} den={p.agentComments} value={p.precision} />
                  </td>
                  <td>
                    <Ratio num={p.matched} den={p.humanComments} value={p.recall} />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </details>
    </figure>
  );
}