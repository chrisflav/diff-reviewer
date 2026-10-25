import { formatRatio } from "../calibration";

/**
 * A ratio as a percentage beside its numerator and denominator, `75% (3/4)`, so that one resting
 * on few comments is plain to see; marked `few` below `FEW` in the denominator.
 */
export function Ratio({ num, den, value }: { num: number; den: number; value?: number | null }) {
  const r = formatRatio(num, den, value);
  return (
    <span className={`ratio${r.defined ? "" : " undefined"}`}>
      <span aria-hidden="true">
        <span className="pct">{r.percent}</span> <span className="frac">({r.fraction})</span>
        {r.defined && r.few && <span className="few">few</span>}
      </span>
      <span className="sr-only">
        {r.label}
        {r.defined && r.few && ", few to go on"}
      </span>
    </span>
  );
}