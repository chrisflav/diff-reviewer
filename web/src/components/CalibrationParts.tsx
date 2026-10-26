import type { ReactNode } from "react";
import type { AgentComment, CalibrationAggregate, CalibrationScore, HumanComment } from "../api";
import { decisionTable, groupPairs, lines } from "../calibration";
import { severityRank } from "../review";
import { Ratio } from "./Ratio";
import { CategoryTag, SeverityBadge } from "./Severity";

/** The figures of an aggregate: precision, recall, agreement, and what they are of. */
export function AggregateFigures({ a }: { a: CalibrationAggregate }) {
  return (
    <>
      <dl className="figures">
        <div>
          <dt>Precision</dt>
          <dd>
            <Ratio num={a.matched} den={a.agentComments} value={a.precision} />
          </dd>
          <dd className="mute small-text">paired agent comments / all agent comments</dd>
        </div>
        <div>
          <dt>Recall</dt>
          <dd>
            <Ratio num={a.matched} den={a.humanComments} value={a.recall} />
          </dd>
          <dd className="mute small-text">paired person comments / all person comments</dd>
        </div>
        <div>
          <dt>Decision agreement</dt>
          <dd>
            <Ratio
              num={a.decisions.agreed}
              den={a.decisions.compared}
              value={a.decisions.agreement}
            />
          </dd>
          <dd className="mute small-text">same decision / samples compared</dd>
        </div>
      </dl>
      <p className="mute small-text">
        Of {a.scored} scored {a.scored === 1 ? "job" : "jobs"}; precision and recall are of the{" "}
        {a.commentsScored} of <code>full</code> samples, decisions of all.{" "}
        {a.staleScores > 0 &&
          (a.staleIncluded
            ? `${a.staleScores} stale ${a.staleScores === 1 ? "score is" : "scores are"} counted.`
            : `${a.staleScores} stale ${a.staleScores === 1 ? "score is" : "scores are"} left out.`)}{" "}
        {(a.derivedScores ?? 0) > 0 &&
          (a.derivedIncluded === true
            ? `${a.derivedScores} derived ${a.derivedScores === 1 ? "score is" : "scores are"} counted.`
            : `${a.derivedScores} derived ${a.derivedScores === 1 ? "score is" : "scores are"} left out.`)}{" "}
        Matcher version <span className="data">{a.matcherVersion}</span>.
      </p>
    </>
  );
}

/** Precision by category and by severity of the agent's comments, and the decision matrix. */
export function AggregateBreakdown({ a }: { a: CalibrationAggregate }) {
  return (
    <div className="breakdown">
      <Tally
        caption="Precision by category of the agent's comments"
        head="Category"
        rows={a.byCategory.map((t) => ({
          key: t.category ?? "\u0000",
          label: t.category === null ? <span className="mute">none</span> : t.category,
          ...t,
        }))}
      />
      <Tally
        caption="Precision by severity of the agent's comments"
        head="Severity"
        rows={a.bySeverity.map((t) => ({
          key: t.severity ?? "\u0000",
          label:
            t.severity === null ? (
              <span className="mute">none</span>
            ) : (
              <SeverityName s={t.severity} />
            ),
          ...t,
        }))}
      />
      <Matrix a={a} />
    </div>
  );
}

/** A severity as a badge, or as text when this build does not know it. */
function SeverityName({ s }: { s: string }) {
  return severityRank(s) < 0 ? <span className="data">{s}</span> : <SeverityBadge severity={s} />;
}

function Tally({
  caption,
  head,
  rows,
}: {
  caption: string;
  head: string;
  rows: {
    key: string;
    label: ReactNode;
    comments: number;
    matched: number;
    precision: number | null;
  }[];
}) {
  return (
    <div className="table-scroll">
      <table className="tally">
        <caption>{caption}</caption>
        <thead>
          <tr>
            <th scope="col">{head}</th>
            <th scope="col">Agent comments (n)</th>
            <th scope="col">Paired</th>
            <th scope="col">Precision</th>
          </tr>
        </thead>
        <tbody>
          {rows.length === 0 ? (
            <tr>
              <td colSpan={4} className="mute">
                No agent comments scored.
              </td>
            </tr>
          ) : (
            rows.map((r) => (
              <tr key={r.key}>
                <th scope="row">{r.label}</th>
                <td className="data">{r.comments}</td>
                <td className="data">{r.matched}</td>
                <td>
                  <Ratio num={r.matched} den={r.comments} value={r.precision} />
                </td>
              </tr>
            ))
          )}
        </tbody>
      </table>
    </div>
  );
}

/**
 * The agent's decisions against the person's, as counts. A state that stands for no decision
 * (`DISMISSED`) is in the matrix but not compared: its column is marked, and left out of the
 * agreement.
 */
function Matrix({ a }: { a: CalibrationAggregate }) {
  const t = decisionTable(a.decisions.matrix);
  if (t.agents.length === 0) return <p className="mute small-text">No decisions compared yet.</p>;
  return (
    <div className="table-scroll">
      <table className="tally">
        <caption>
          Decisions: the agent's (rows) against the person's (columns); {t.compared} compared
          {t.notCompared > 0 &&
            `, ${t.notCompared} not (the person's review stood for no decision)`}
        </caption>
        <thead>
          <tr>
            <th scope="col">Agent \ person</th>
            {t.humans.map((h) => (
              <th key={h.state} scope="col" className={h.compared ? "data" : "data mute"}>
                {h.state}
                {!h.compared && <span className="small-text"> (not compared)</span>}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {t.agents.map((ag) => (
            <tr key={ag}>
              <th scope="row" className="data">
                {ag}
              </th>
              {t.humans.map((h) => (
                <td key={h.state} className={h.compared ? "data" : "data mute"}>
                  {t.count(ag, h.state)}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function AgentSide({ c }: { c: AgentComment }) {
  return (
    <article className="comment side-agent">
      <header>
        <span className="author">agent</span>{" "}
        <span className="data">
          {c.file}:{lines(c.start_line, c.end_line)}
        </span>
        <span className="labels">
          <SeverityBadge severity={c.severity} />
          <CategoryTag category={c.category} />
        </span>
      </header>
      <p className="body">{c.body}</p>
    </article>
  );
}

function HumanSide({ c, reviewer }: { c: HumanComment; reviewer: string | null }) {
  return (
    <article className="comment side-human">
      <header>
        <span className="author">{reviewer ?? "person"}</span>{" "}
        <span className="data">
          {c.path}:{lines(c.start_line, c.line)}
        </span>
      </header>
      <p className="body">{c.body}</p>
    </article>
  );
}

/**
 * A score's comments by file: each pair side by side (the agent's left, the person's right), and
 * the comments left unpaired on either side in their column. Everything they say is shown as text.
 */
export function PairView({
  score,
  reviewer,
}: {
  score: Pick<CalibrationScore, "pairs" | "unmatchedAgent" | "unmatchedHuman">;
  reviewer: string | null;
}) {
  const files = groupPairs(score);
  if (files.length === 0) return <p className="mute">Neither side made an inline comment.</p>;
  return (
    <div className="pairs">
      {files.map((f) => (
        <section key={f.file} className="pair-file">
          <h4 className="data">{f.file}</h4>
          <p className="mute small-text">
            {f.pairs} paired, {f.agentOnly} only the agent's, {f.humanOnly} only the person's
          </p>
          <ol className="pair-rows">
            {f.rows.map((r, i) => (
              <li
                key={r.kind === "pair" ? r.key : `${r.kind}-${i}`}
                className={`pair-row ${r.kind}`}
              >
                <div className="pair-label small-text">
                  {r.kind === "pair"
                    ? r.gap === 0
                      ? "paired: the ranges overlap"
                      : `paired: ${r.gap} ${r.gap === 1 ? "line" : "lines"} apart`
                    : r.kind === "agent"
                      ? "only the agent's: no comment of the person's near it"
                      : "only the person's: missed by the agent"}
                </div>
                <div className="pair-cols">
                  <div className="col-agent">
                    {r.kind !== "human" ? (
                      <AgentSide c={r.agent} />
                    ) : (
                      <p className="mute small-text gap-side">no agent comment</p>
                    )}
                  </div>
                  <div className="col-human">
                    {r.kind !== "agent" ? (
                      <HumanSide c={r.human} reviewer={reviewer} />
                    ) : (
                      <p className="mute small-text gap-side">no comment of the person's</p>
                    )}
                  </div>
                </div>
              </li>
            ))}
          </ol>
        </section>
      ))}
    </div>
  );
}

/** What the numbers mean and where they stop meaning it, from the README. */
export function Limits({ open = false }: { open?: boolean }) {
  return (
    <details className="limits" open={open}>
      <summary>What the numbers mean, and their limits</summary>
      <p>
        The agent reviews a commit a trusted reviewer has already reviewed, without being shown that
        review, and its inline comments are paired with the person's one to one, greedily, closest
        first: two comments can pair when they are on the same file and their line ranges overlap or
        are at most 3 lines apart.
      </p>
      <ul>
        <li>
          <strong>Precision</strong>: paired agent comments over all agent comments, how much of
          what the agent says is on something the person also commented on. Also by category and by
          severity of the agent's comments.
        </li>
        <li>
          <strong>Recall</strong>: paired person comments over all person comments, how much of what
          the person raised the agent found.
        </li>
        <li>
          <strong>Decision agreement</strong>: whether the agent's decision is the person's; a
          dismissed review is not compared.
        </li>
        <li>
          Every ratio is shown with its numerator and denominator. Aggregates add counts first and
          divide last, so every comment weighs the same. A denominator under 10 is marked{" "}
          <span className="few">few</span>: one comment more or less moves the ratio by a tenth or
          more.
        </li>
      </ul>
      <h3>Limits</h3>
      <ul>
        <li>
          <strong>Pairing is by place only.</strong> Two comments on the same lines may say
          different things, and two that say the same may be a screen apart; a comment the person
          put on the call site and the agent on the definition is a miss on both sides. Read
          precision and recall as how often the agent looks where a person looks, not as how often
          it is right.
        </li>
        <li>
          <strong>A person's review is not ground truth.</strong> People skip what is fine, comment
          on what an agent is told not to, and spread one review over several. An agent comment with
          no pair may be right, and a person's the agent missed may be a matter of taste. Few
          samples make for noisy numbers.
        </li>
        <li>
          <strong>Partial and decision samples.</strong> Precision and recall are of{" "}
          <code>full</code> samples only. A <code>partial</code> sample had comments dropped (on the
          old side, or not anchored to the reviewed commit), so its comments are not the whole
          review; a <code>decision</code> sample says nothing but its approval or request for
          changes. Both count for their decision only.
        </li>
        <li>
          <strong>What isolation is not.</strong> The agent's checkout is the reviewed commit and
          its history only, with no branch, no remote and nothing after it, and it cannot read
          GitHub's API; but it still has the network, and could fetch the pull request's later
          commits from GitHub by their URL. It is told to fetch nothing.
        </li>
        <li>
          <strong>Stale scores.</strong> A review imported after a run scored its sample joins the
          sample; the earlier score is kept as it was and marked stale. Aggregates leave stale
          scores out unless asked to include them. A fresh score needs a fresh run.
        </li>
        <li>
          <strong>Derived scores.</strong> A rubric or style notes version made from a rubric
          proposal records the pull requests the proposal drew on. A score of one of them, made
          under that version, is derived: what measures the rubric would be what it learned from.
          Aggregates leave derived scores out unless asked to include them.
        </li>
        <li>
          <strong>Held out.</strong> Each pull request's samples are <code>eval</code> or{" "}
          <code>pool</code>, once and for good. Runs and aggregates are of <code>eval</code>{" "}
          samples; the pool is what the style examples and rubric proposals learn from, and a run of
          it is never counted.
        </li>
        <li>
          <strong>Deleted samples</strong> are left out of every aggregate, and still shown, marked,
          in their runs.
        </li>
        <li>
          <strong>The base is reconstructed</strong> as the merge base of the pull request's base
          now and the reviewed commit; a commit a force-push left unreferenced may be gone, and its
          reviews are not stored.
        </li>
      </ul>
    </details>
  );
}