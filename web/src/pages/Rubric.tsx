import { useCallback, useContext, useEffect, useMemo, useRef, useState } from "react";
import { Link, useBlocker, useParams, useSearchParams } from "react-router-dom";
import { api, ApiError, UnauthorizedError, type RubricDocument } from "../api";
import { loadAdoption, proposalPath, saveRubricEdits } from "../proposals";
import {
  alignRubric,
  documentOf,
  freshRubricKeys,
  MAX_CATEGORIES,
  MAX_NAME_LENGTH,
  MAX_PR_TYPES,
  MAX_RUBRIC_BYTES,
  move,
  RKEY,
  rebaseRubric,
  resolveRubric,
  rubricConflictId,
  rubricProblems,
  sameRubric,
  toLocalRubric,
  toRubricDoc,
  type LocalCategory,
  type LocalRubric,
  type LocalType,
  type RubricConflict,
  type RubricDoc,
  type RubricPick,
  type RubricProblem,
} from "../rubric";
import {
  dropRubricStash,
  reopenRubric,
  rubricStashKey,
  stashRubric,
  unstashRubric,
  type RubricEdits,
  type StashedRubric,
} from "../stash";
import { charLength, utf8Bytes } from "../text";
import { UnsavedContext } from "../unsaved";
import { useLoad } from "../useLoad";

const emptyDoc: RubricDoc = { defaultRubric: "", prTypes: [] };

type Modify = (f: (d: LocalRubric, base: LocalRubric) => LocalRubric) => void;

interface Rebased {
  from: number;
  to: number;
  conflicts: RubricConflict[];
  picks: Record<string, RubricPick>;
  /** The edits from before the move: what storage keeps until every conflict is settled. */
  source: RubricEdits;
}

export function RubricPage({ onUnauthorized }: { onUnauthorized: () => void }) {
  const { owner = "", name = "" } = useParams();
  // Keyed by the repository: one repository's edits never reach another's page.
  return (
    <RubricView
      key={`${owner}/${name}`}
      owner={owner}
      name={name}
      onUnauthorized={onUnauthorized}
    />
  );
}

function RubricView({
  owner,
  name,
  onUnauthorized,
}: {
  owner: string;
  name: string;
  onUnauthorized: () => void;
}) {
  const repo = rubricStashKey(owner, name);
  const fetchDoc = useCallback(() => api.rubrics(owner, name), [owner, name]);
  const { data: doc, error, reload, setError, setData: setDoc } = useLoad(fetchDoc, onUnauthorized);

  const [edits, setEdits] = useState<RubricEdits | null>(null);
  const [conflict, setConflict] = useState<string | null>(null);
  const [rebased, setRebased] = useState<Rebased | null>(null);
  const [busy, setBusy] = useState(false);
  const [savedNote, setSavedNote] = useState<string | null>(null);
  const [historyNonce, setHistoryNonce] = useState(0);
  const [offer, setOffer] = useState<StashedRubric | null>(() => {
    const s = unstashRubric(repo);
    return s !== null &&
      (s.pending !== null || s.fromProposal !== undefined || !sameRubric(s.base, s.doc))
      ? s
      : null;
  });
  // `?proposal=<id>`: that rubric proposal, to be opened here as unsaved edits and rebased.
  const [params, setParams] = useSearchParams();
  const adopt = params.get("proposal");
  const [adoptBusy, setAdoptBusy] = useState(false);
  const tried = useRef<string | null>(null);
  const mergeOntoRef = useRef<
    ((d: RubricDocument, e: RubricEdits, announce: boolean) => void) | null
  >(null);

  const readable = useMemo(() => (doc === null ? null : documentOf(doc)), [doc]);
  const saved = useMemo(() => toLocalRubric(readable ?? emptyDoc), [readable]);
  const current = edits?.doc ?? saved;

  const baseRef = useRef({ version: 0, doc: saved });
  baseRef.current = { version: doc?.version ?? 0, doc: saved };
  const editsRef = useRef(edits);
  editsRef.current = edits;

  const modify = useCallback<Modify>(
    (f) =>
      setEdits((e) => {
        if (e !== null) return { ...e, doc: f(e.doc, e.base) };
        const { version, doc: d } = baseRef.current;
        return { repo, version, base: d, doc: f(d, d) };
      }),
    [repo],
  );

  const unresolved =
    rebased !== null &&
    rebased.conflicts.some((c) => rebased.picks[rubricConflictId(c)] === undefined);
  // Open conflicts count: what they are left at may be the newer version itself. So does adopting
  // a proposal, even one that says what the rubric says: the save records where it came from.
  const dirty =
    edits !== null &&
    (unresolved || edits.fromProposal !== undefined || !sameRubric(edits.base, edits.doc));

  // Every change is kept in the tab's storage, with the conflicts still open and the sides picked
  // so far, so that a 401 or a reload brings back the page as it was.
  const [memoryOnly, setMemoryOnly] = useState(false);
  useEffect(() => {
    if (edits === null) return;
    const pending =
      unresolved && rebased !== null
        ? { from: rebased.from, source: rebased.source, picks: rebased.picks }
        : null;
    setMemoryOnly(!stashRubric(edits, pending));
  }, [edits, rebased, unresolved]);

  const unsaved = useContext(UnsavedContext);
  useEffect(() => {
    unsaved.current = dirty;
    return () => {
      unsaved.current = false;
    };
  }, [unsaved, dirty]);

  useEffect(() => {
    if (!dirty) return;
    const warn = (e: BeforeUnloadEvent) => e.preventDefault();
    window.addEventListener("beforeunload", warn);
    return () => window.removeEventListener("beforeunload", warn);
  }, [dirty]);

  const blocker = useBlocker(
    ({ currentLocation, nextLocation }) =>
      dirty && currentLocation.pathname !== nextLocation.pathname,
  );
  useEffect(() => {
    if (blocker.state !== "blocked") return;
    if (
      window.confirm(
        "This rubric has unsaved edits. Leave anyway? They are kept in this tab and offered back when you open it again.",
      )
    )
      blocker.proceed();
    else blocker.reset();
  }, [blocker]);

  const problems = useMemo(() => rubricProblems(toRubricDoc(current)), [current]);

  const dropAdoptParam = useCallback(
    () =>
      setParams(
        (p) => {
          const n = new URLSearchParams(p);
          n.delete("proposal");
          return n;
        },
        { replace: true },
      ),
    [setParams],
  );

  // A proposal named in the address is opened once the rubric is loaded: its document as edits to
  // the version it was written from, moved onto the current one by the three-way merge. Edits this
  // tab holds already are asked about first.
  useEffect(() => {
    if (adopt === null || doc === null || adoptBusy || tried.current === adopt) return;
    if (offer !== null) {
      if (offer.fromProposal === adopt) dropAdoptParam();
      return;
    }
    if (edits?.fromProposal === adopt) {
      dropAdoptParam();
      return;
    }
    if (
      dirty &&
      !window.confirm(`Replace your unsaved edits of the rubric with proposal ${adopt}?`)
    ) {
      dropAdoptParam();
      return;
    }
    tried.current = adopt;
    setAdoptBusy(true);
    loadAdoption(owner, name, adopt)
      .then((e) => {
        setSavedNote(null);
        setConflict(null);
        if (typeof e === "string") {
          setError(e);
          return;
        }
        setError(null);
        setRebased(null);
        // The current version, read now: the merge is onto what a save would be checked against.
        return api.rubrics(owner, name).then((d) => {
          mergeOntoRef.current?.(d, e, true);
          setHistoryNonce((n) => n + 1);
          requestAnimationFrame(() => document.getElementById("adopt-h")?.focus());
        });
      })
      .catch((err: unknown) => {
        if (err instanceof UnauthorizedError) return onUnauthorized();
        setError(err instanceof Error ? err.message : String(err));
      })
      .finally(() => {
        setAdoptBusy(false);
        dropAdoptParam();
      });
  }, [adopt, doc, offer, edits, dirty, adoptBusy, owner, name, dropAdoptParam, onUnauthorized]);

  if (doc === null)
    return error !== null ? (
      <>
        <Crumbs />
        <p className="error">{error}</p>
      </>
    ) : (
      <p className="mute">Loading…</p>
    );

  const editable = readable !== null && offer === null;

  const fail = (err: unknown) => {
    if (err instanceof UnauthorizedError) return onUnauthorized();
    if (err instanceof ApiError && err.status === 409) setConflict(err.message);
    else setError(err instanceof Error ? err.message : String(err));
  };

  const mergeOnto = (d: RubricDocument, e: RubricEdits, announce: boolean) => {
    setDoc(d);
    const theirs = documentOf(d);
    if (theirs === null) {
      setEdits(e);
      setError(
        `Version ${d.version} of the rubric cannot be read by this version, so your edits could not be moved onto it. They are kept in this tab.`,
      );
      return;
    }
    const r = rebaseRubric(e.base, e.doc, theirs);
    const adopting = e.fromProposal;
    if (adopting === undefined && r.conflicts.length === 0 && sameRubric(r.review, r.base)) {
      setEdits(null);
      setRebased(null);
      dropRubricStash(repo);
      return;
    }
    setEdits({
      repo,
      version: d.version,
      base: r.base,
      doc: r.review,
      ...(adopting === undefined ? {} : { fromProposal: adopting }),
    });
    setRebased(
      announce || r.conflicts.length > 0
        ? { from: e.version, to: d.version, conflicts: r.conflicts, picks: {}, source: e }
        : null,
    );
  };
  mergeOntoRef.current = mergeOnto;

  const save = () => {
    const sent = edits;
    if (sent === null || unresolved || problems.length > 0) return;
    setBusy(true);
    setError(null);
    setSavedNote(null);
    saveRubricEdits(owner, name, sent)
      .then((d) => {
        setHistoryNonce((n) => n + 1);
        setSavedNote(
          `Saved as version ${d.version}.${
            sent.fromProposal === undefined
              ? ""
              : ` It records proposal ${sent.fromProposal} as what it was derived from, and the proposal is accepted.`
          }`,
        );
        const now = editsRef.current;
        if (now === null || now === sent) {
          setDoc(d);
          setEdits(null);
          setRebased(null);
          dropRubricStash(repo);
        } else {
          // Edits made while the save was under way: the proposal is adopted already.
          const rest: RubricEdits = { ...now, version: sent.version, base: sent.doc };
          delete rest.fromProposal;
          mergeOnto(d, rest, false);
        }
      })
      .catch(fail)
      .finally(() => setBusy(false));
  };

  const discard = () => {
    setEdits(null);
    setRebased(null);
    dropRubricStash(repo);
    setError(null);
  };

  const reloadDiscarding = () => {
    discard();
    setConflict(null);
    reload();
    setHistoryNonce((n) => n + 1);
  };

  const reloadMerging = () => {
    setBusy(true);
    api
      .rubrics(owner, name)
      .then((d) => {
        setConflict(null);
        setHistoryNonce((n) => n + 1);
        const e = editsRef.current;
        if (e === null) setDoc(d);
        else mergeOnto(d, e, true);
      })
      .catch(fail)
      .finally(() => setBusy(false));
  };

  const pick = (c: RubricConflict, which: RubricPick) => {
    setRebased((rb) =>
      rb === null ? rb : { ...rb, picks: { ...rb.picks, [rubricConflictId(c)]: which } },
    );
    modify((d) => resolveRubric(d, c, which));
  };

  const restoreOffer = () => {
    if (offer === null) return;
    setOffer(null);
    if (offer.pending === null) {
      mergeOnto(doc, offer, offer.version !== doc.version);
      return;
    }
    const back = reopenRubric(offer);
    if (back === null) {
      // The open conflicts cannot be worked out again: the edits from before them are moved anew.
      mergeOnto(doc, offer.pending.source, true);
      return;
    }
    setEdits(back.edits);
    setRebased(back.rebased);
    if (offer.version !== doc.version)
      setError(
        `The rubric is at version ${doc.version} now. Settle the conflicts below first; saving then offers to move your edits onto version ${doc.version}.`,
      );
  };

  const dropOffer = () => {
    dropRubricStash(repo);
    setOffer(null);
  };

  /** An old version into the editor, as edits to the current one: saving makes it the newest. */
  const restoreVersion = (v: RubricDocument) => {
    const old = documentOf(v);
    if (old === null || readable === null) return;
    if (
      dirty &&
      !window.confirm(`Replace your unsaved edits with version ${v.version} of the rubric?`)
    )
      return;
    setRebased(null);
    setSavedNote(null);
    setEdits({
      repo,
      version: doc.version,
      base: saved,
      doc: alignRubric(saved, old, freshRubricKeys(saved)),
    });
    requestAnimationFrame(() => document.getElementById("rubric-editor-h")?.focus());
  };

  return (
    <>
      <Crumbs />
      <h1>
        Rubric of <span className="data">{repo}</span>
      </h1>
      <dl className="facts">
        <dt>Version</dt>
        <dd className="data">{doc.version === 0 ? "none yet" : doc.version}</dd>
        <dt>Written</dt>
        <dd className="data">{doc.createdAt ?? "—"}</dd>
        {doc.derivedFrom !== undefined && (
          <>
            <dt>Derived from</dt>
            <dd>{derivedSummary(doc)}</dd>
          </>
        )}
      </dl>
      <p className="mute small-text">
        The default rubric is what every review of the repository looks at. A pull request type is a
        kind of change reviewed differently: its description says how to recognise it (the agent
        picks the type by it), its rubric what to look at on top of the default, and its categories
        what its comments are filed under. Rubrics go to the agent as they are written, as markdown.
        Every save is a new version; the old ones are kept.
      </p>

      {offer !== null && (
        <div className="notice warn-notice" role="alert">
          <p>
            This tab holds unsaved edits to this rubric from earlier (made to version{" "}
            {offer.version}, kept {offer.savedAt}).
            {offer.version !== doc.version &&
              ` The rubric is at version ${doc.version} now; restoring moves them onto it, and asks where both changed the same thing.`}
            {offer.fromProposal !== undefined && ` They adopt proposal ${offer.fromProposal}.`}
            {adopt !== null &&
              offer.fromProposal !== adopt &&
              ` You asked to open proposal ${adopt}, which would replace them.`}
          </p>
          <div className="actions">
            <button
              type="button"
              onClick={() => {
                if (adopt !== null && offer.fromProposal !== adopt) dropAdoptParam();
                restoreOffer();
              }}
            >
              Restore them
            </button>
            <button type="button" className="ghost" onClick={dropOffer}>
              {adopt !== null && offer.fromProposal !== adopt
                ? `Discard them, open proposal ${adopt}`
                : "Discard them"}
            </button>
          </div>
        </div>
      )}
      {error !== null && (
        <p className="error" role="alert">
          {error}
        </p>
      )}
      {savedNote !== null && !dirty && (
        <p className="notice" role="status">
          {savedNote}
        </p>
      )}
      {conflict !== null && (
        <div className="notice warn-notice" role="alert">
          <p>The rubric changed since this page loaded it, so nothing was saved: {conflict}</p>
          {edits !== null ? (
            <>
              <p>
                Your edits are still here. Reload the rubric and move them onto it (where you and
                the other change touched the same thing, you choose), or drop them.
              </p>
              <div className="actions">
                <button type="button" onClick={reloadMerging} disabled={busy}>
                  Reload and keep my edits
                </button>
                <button type="button" className="ghost" onClick={reloadDiscarding}>
                  Reload, discard my edits
                </button>
              </div>
            </>
          ) : (
            <div className="actions">
              <button type="button" onClick={reloadDiscarding}>
                Reload
              </button>
            </div>
          )}
        </div>
      )}
      {adoptBusy && <p className="mute">Opening the proposal…</p>}
      {edits?.fromProposal !== undefined && (
        <section className="notice adopt-notice" aria-labelledby="adopt-h">
          <h2 id="adopt-h" tabIndex={-1}>
            Adopting proposal{" "}
            <Link className="data" to={proposalPath(owner, name, edits.fromProposal)}>
              {edits.fromProposal}
            </Link>
          </h2>
          <p>
            The editor below holds the proposal's document as unsaved edits on top of version{" "}
            {edits.version === 0 ? "none" : edits.version} of the rubric. Change it as you like.
            Saving makes it version {doc.version + 1} and names the proposal: the version records
            what the proposal was derived from, and the proposal is accepted.
          </p>
          <div className="actions">
            <button type="button" className="ghost" onClick={discard} disabled={busy}>
              Stop adopting, discard the edits
            </button>
          </div>
        </section>
      )}
      {rebased !== null && edits !== null && (
        <ConflictNotice rebased={rebased} onPick={pick} adopting={edits.fromProposal} />
      )}

      {readable === null ? (
        <div className="notice danger-notice" role="alert">
          <p>
            Version {doc.version} of the rubric cannot be read by this version of the platform:{" "}
            <span className="body">{doc.documentError}</span>
          </p>
          <p>
            It is shown read-only and is not overwritten: a build that can read it must change it.
            Older versions can still be viewed below.
          </p>
        </div>
      ) : (
        <Editor doc={current} editable={editable} modify={modify} problems={problems} />
      )}

      <RubricHistory
        owner={owner}
        name={name}
        current={doc}
        nonce={historyNonce}
        canRestore={editable}
        onRestore={restoreVersion}
        onUnauthorized={onUnauthorized}
      />

      {dirty && (
        <div className="savebar" role="region" aria-label="Unsaved changes">
          <span>
            Unsaved changes to the rubric.
            {memoryOnly && " This tab cannot store them, so they are held in memory only."}
            {unresolved && " Choose a side for each conflict above before saving."}
            {!unresolved && problems.length > 0 && (
              <span className="warn">
                {" "}
                {problems.length === 1 ? "One problem" : `${problems.length} problems`} to fix
                first: {problems[0]?.message}.
              </span>
            )}
          </span>
          <span className="actions">
            <button
              type="button"
              onClick={save}
              disabled={busy || !editable || unresolved || problems.length > 0}
            >
              Save as version {doc.version + 1}
            </button>
            <button type="button" className="ghost" onClick={discard} disabled={busy}>
              Discard
            </button>
          </span>
        </div>
      )}
    </>
  );
}

function Crumbs() {
  return (
    <p className="crumbs">
      <Link to="/repos">Repositories</Link>
    </p>
  );
}

/** Problems at one place of the document, for that field's message. */
function problemsAt(
  ps: RubricProblem[],
  at: { type?: number; category?: number; field: RubricProblem["field"] },
): string[] {
  return ps
    .filter((p) => p.field === at.field && p.type === at.type && p.category === at.category)
    .map((p) => p.message);
}

function FieldProblems({ id, messages }: { id: string; messages: string[] }) {
  if (messages.length === 0) return null;
  return (
    <p id={id} className="error small-text">
      {messages.join("; ")}.
    </p>
  );
}

function Editor({
  doc,
  editable,
  modify,
  problems,
}: {
  doc: LocalRubric;
  editable: boolean;
  modify: Modify;
  problems: RubricProblem[];
}) {
  const setType = (key: number, f: (t: LocalType) => LocalType) =>
    modify((d) => ({ ...d, prTypes: d.prTypes.map((t) => (t[RKEY] === key ? f(t) : t)) }));

  // The id is asked for when focus moves, by when the edit that makes the element has been drawn.
  const focusLater = (id: string | (() => string)) =>
    requestAnimationFrame(() =>
      document.getElementById(typeof id === "string" ? id : id())?.focus(),
    );

  const addType = () => {
    let added = -1;
    modify((d, b) => {
      added = freshRubricKeys(d, b)();
      return {
        ...d,
        prTypes: [
          ...d.prTypes,
          { name: "", description: "", rubric: "", categories: [], [RKEY]: added },
        ],
      };
    });
    focusLater(() => `type-${added}-name`);
  };

  const addCategory = (typeKey: number) => {
    let added = -1;
    modify((d, b) => {
      added = freshRubricKeys(d, b)();
      return {
        ...d,
        prTypes: d.prTypes.map((t) =>
          t[RKEY] === typeKey
            ? { ...t, categories: [...t.categories, { name: "", description: "", [RKEY]: added }] }
            : t,
        ),
      };
    });
    focusLater(() => `cat-${typeKey}-${added}-name`);
  };

  const docProblems = problemsAt(problems, { field: "defaultRubric" });
  const typesProblems = problemsAt(problems, { field: "prTypes" });

  return (
    <section aria-labelledby="rubric-editor-h" className="rubric-editor">
      <h2 id="rubric-editor-h" tabIndex={-1}>
        Default rubric
      </h2>
      <RubricText
        id="default-rubric"
        label="Default rubric"
        value={doc.defaultRubric}
        editable={editable}
        problems={docProblems}
        onChange={(v) => modify((d) => ({ ...d, defaultRubric: v }))}
        rows={10}
      />

      <h2 id="types-h">Pull request types</h2>
      <p className="mute small-text">
        {doc.prTypes.length} of at most {MAX_PR_TYPES}. A job records the type it was reviewed as by
        name, next to the rubric version: renaming a type does not change past reviews.
      </p>
      <FieldProblems id="types-problems" messages={typesProblems} />
      {doc.prTypes.length === 0 && (
        <p className="mute">
          No types: every pull request is reviewed by the default rubric, and a comment's category
          is free text.
        </p>
      )}
      <ol className="types">
        {doc.prTypes.map((t, i) => (
          <li key={t[RKEY]}>
            <TypeEditor
              t={t}
              index={i}
              count={doc.prTypes.length}
              editable={editable}
              problems={problems}
              set={(f) => setType(t[RKEY], f)}
              onAddCategory={() => addCategory(t[RKEY])}
              onMove={(by) => {
                modify((d) => ({ ...d, prTypes: move(d.prTypes, i, by) }));
                focusLater(`type-${t[RKEY]}-${by < 0 ? "up" : "down"}`);
              }}
              onRemove={() => {
                const next = doc.prTypes[i + 1] ?? doc.prTypes[i - 1];
                modify((d) => ({ ...d, prTypes: d.prTypes.filter((x) => x[RKEY] !== t[RKEY]) }));
                focusLater(next === undefined ? "add-type" : `type-${next[RKEY]}-name`);
              }}
            />
          </li>
        ))}
      </ol>
      {editable && (
        <button
          id="add-type"
          type="button"
          className="ghost"
          onClick={addType}
          disabled={doc.prTypes.length >= MAX_PR_TYPES}
        >
          Add a pull request type
        </button>
      )}
    </section>
  );
}

/** A rubric's markdown: a plain textarea, and beside it the text as the agent gets it. */
function RubricText({
  id,
  label,
  value,
  editable,
  problems,
  onChange,
  rows,
}: {
  id: string;
  label: string;
  value: string;
  editable: boolean;
  problems: string[];
  onChange: (v: string) => void;
  rows: number;
}) {
  const bytes = utf8Bytes(value);
  return (
    <div className="rubric-text">
      <div className="pane">
        <label htmlFor={id}>{label}</label>
        <textarea
          id={id}
          className="data"
          rows={Math.min(24, Math.max(rows, value.split("\n").length + 1))}
          value={value}
          readOnly={!editable}
          spellCheck
          aria-invalid={problems.length > 0}
          aria-describedby={`${id}-size${problems.length > 0 ? ` ${id}-problems` : ""}`}
          onChange={(e) => onChange(e.target.value)}
        />
        <p
          id={`${id}-size`}
          className={`small-text ${bytes > MAX_RUBRIC_BYTES ? "error" : "mute"}`}
        >
          {bytes} of {MAX_RUBRIC_BYTES} bytes
        </p>
        <FieldProblems id={`${id}-problems`} messages={problems} />
      </div>
      <div className="pane">
        <span className="pane-label" id={`${id}-preview-l`}>
          Preview, as the agent reads it
        </span>
        <div className="preview body" role="region" aria-labelledby={`${id}-preview-l`}>
          {value === "" ? <span className="mute">(empty)</span> : value}
        </div>
      </div>
    </div>
  );
}

function TypeEditor({
  t,
  index,
  count,
  editable,
  problems,
  set,
  onAddCategory,
  onMove,
  onRemove,
}: {
  t: LocalType;
  index: number;
  count: number;
  editable: boolean;
  problems: RubricProblem[];
  set: (f: (t: LocalType) => LocalType) => void;
  onAddCategory: () => void;
  onMove: (by: number) => void;
  onRemove: () => void;
}) {
  const k = t[RKEY];
  const title = t.name.trim() === "" ? `Type ${index + 1} (unnamed)` : t.name;
  const nameProblems = problemsAt(problems, { type: index, field: "name" });
  const setCats = (f: (cs: LocalCategory[]) => LocalCategory[]) =>
    set((x) => ({ ...x, categories: f(x.categories) }));
  const focusLater = (id: string) =>
    requestAnimationFrame(() => document.getElementById(id)?.focus());

  return (
    <fieldset className="type" aria-labelledby={`type-${k}-legend`}>
      <legend id={`type-${k}-legend`}>{title}</legend>
      {editable && (
        <div className="actions type-tools">
          <button
            id={`type-${k}-up`}
            type="button"
            className="ghost small"
            disabled={index === 0}
            onClick={() => onMove(-1)}
            aria-label={`Move ${title} up`}
          >
            Up
          </button>
          <button
            id={`type-${k}-down`}
            type="button"
            className="ghost small"
            disabled={index === count - 1}
            onClick={() => onMove(1)}
            aria-label={`Move ${title} down`}
          >
            Down
          </button>
          <button
            type="button"
            className="ghost small danger"
            onClick={onRemove}
            aria-label={`Remove ${title}`}
          >
            Remove
          </button>
        </div>
      )}
      <label className="field">
        Name
        <input
          id={`type-${k}-name`}
          className="data"
          value={t.name}
          readOnly={!editable}
          aria-invalid={nameProblems.length > 0}
          aria-describedby={nameProblems.length > 0 ? `type-${k}-name-p` : undefined}
          onChange={(e) => {
            const v = e.target.value;
            set((x) => ({ ...x, name: v }));
          }}
        />
        <span className="mute small-text">
          {charLength(t.name)} of {MAX_NAME_LENGTH} characters
        </span>
      </label>
      <FieldProblems id={`type-${k}-name-p`} messages={nameProblems} />
      <label className="field">
        Description: when the type applies
        <textarea
          rows={2}
          value={t.description}
          readOnly={!editable}
          onChange={(e) => {
            const v = e.target.value;
            set((x) => ({ ...x, description: v }));
          }}
        />
      </label>
      <RubricText
        id={`type-${k}-rubric`}
        label="Rubric, on top of the default"
        value={t.rubric}
        editable={editable}
        problems={problemsAt(problems, { type: index, field: "rubric" })}
        onChange={(v) => set((x) => ({ ...x, rubric: v }))}
        rows={4}
      />
      <h3 className="cats-h">Categories</h3>
      <p className="mute small-text">
        {t.categories.length === 0
          ? "None: a comment on a review of this type may name any category, as free text."
          : `${t.categories.length} of at most ${MAX_CATEGORIES}. A comment on a review of this type is filed under one of them.`}
      </p>
      <FieldProblems
        id={`type-${k}-cats-p`}
        messages={problemsAt(problems, { type: index, field: "categories" })}
      />
      <ol className="cats">
        {t.categories.map((c, j) => {
          const ck = c[RKEY];
          const label = c.name.trim() === "" ? `category ${j + 1}` : c.name;
          const ps = problemsAt(problems, { type: index, category: j, field: "name" });
          return (
            <li key={ck} className="cat">
              <div className="cat-fields">
                <label className="field">
                  Name
                  <input
                    id={`cat-${k}-${ck}-name`}
                    className="data"
                    value={c.name}
                    readOnly={!editable}
                    aria-invalid={ps.length > 0}
                    aria-describedby={ps.length > 0 ? `cat-${k}-${ck}-p` : undefined}
                    onChange={(e) => {
                      const v = e.target.value;
                      setCats((cs) => cs.map((x) => (x[RKEY] === ck ? { ...x, name: v } : x)));
                    }}
                  />
                </label>
                <label className="field grow">
                  What belongs in it
                  <input
                    value={c.description}
                    readOnly={!editable}
                    onChange={(e) => {
                      const v = e.target.value;
                      setCats((cs) =>
                        cs.map((x) => (x[RKEY] === ck ? { ...x, description: v } : x)),
                      );
                    }}
                  />
                </label>
              </div>
              <FieldProblems id={`cat-${k}-${ck}-p`} messages={ps} />
              {editable && (
                <div className="actions">
                  <button
                    id={`cat-${k}-${ck}-up`}
                    type="button"
                    className="ghost small"
                    disabled={j === 0}
                    aria-label={`Move ${label} of ${title} up`}
                    onClick={() => {
                      setCats((cs) => move(cs, j, -1));
                      focusLater(`cat-${k}-${ck}-up`);
                    }}
                  >
                    Up
                  </button>
                  <button
                    id={`cat-${k}-${ck}-down`}
                    type="button"
                    className="ghost small"
                    disabled={j === t.categories.length - 1}
                    aria-label={`Move ${label} of ${title} down`}
                    onClick={() => {
                      setCats((cs) => move(cs, j, 1));
                      focusLater(`cat-${k}-${ck}-down`);
                    }}
                  >
                    Down
                  </button>
                  <button
                    type="button"
                    className="ghost small danger"
                    aria-label={`Remove ${label} of ${title}`}
                    onClick={() => {
                      const next = t.categories[j + 1] ?? t.categories[j - 1];
                      setCats((cs) => cs.filter((x) => x[RKEY] !== ck));
                      focusLater(
                        next === undefined ? `type-${k}-addcat` : `cat-${k}-${next[RKEY]}-name`,
                      );
                    }}
                  >
                    Remove
                  </button>
                </div>
              )}
            </li>
          );
        })}
      </ol>
      {editable && (
        <button
          id={`type-${k}-addcat`}
          type="button"
          className="ghost small"
          disabled={t.categories.length >= MAX_CATEGORIES}
          onClick={onAddCategory}
        >
          Add a category to {title}
        </button>
      )}
    </fieldset>
  );
}

const docFieldLabel: Record<string, string> = { defaultRubric: "The default rubric" };

function showValue(v: unknown): string {
  if (v === undefined || v === null) return "(none)";
  if (typeof v === "string") return v === "" ? "(empty)" : v;
  return JSON.stringify(v, null, 2);
}

function showType(t: LocalType | null): string {
  if (t === null) return "(removed)";
  return `${t.name}\n${t.description}\n\nRubric:\n${t.rubric}\n\nCategories: ${t.categories.map((c) => c.name).join(", ") || "(none)"}`;
}

function showCategory(c: LocalCategory | null): string {
  if (c === null) return "(removed)";
  return `${c.name}: ${c.description}`;
}

function conflictLabel(c: RubricConflict): string {
  switch (c.kind) {
    case "field":
      return docFieldLabel[c.name] ?? `The field "${c.name}"`;
    case "typeField":
      return `The ${c.name} of type ${c.label}`;
    case "type":
      return `The type ${c.label}`;
    case "categoryField":
      return `The ${c.name} of category ${c.label}`;
    case "category":
      return `The category ${c.label}`;
    case "order":
      return `The order of ${c.type === null ? "the types" : c.label}`;
  }
}

function ConflictNotice({
  rebased,
  onPick,
  adopting,
}: {
  rebased: Rebased;
  onPick: (c: RubricConflict, which: RubricPick) => void;
  /** The proposal being adopted, when the edits moved are its document. */
  adopting: string | undefined;
}) {
  const open = rebased.conflicts.filter(
    (c) => rebased.picks[rubricConflictId(c)] === undefined,
  ).length;
  const fromProposal = adopting !== undefined && rebased.source.fromProposal === adopting;
  return (
    <section className="notice warn-notice" aria-labelledby="rebase-h">
      <p id="rebase-h">
        {fromProposal
          ? rebased.from === rebased.to
            ? `Proposal ${adopting} was written from version ${rebased.from}, the current one. It is not saved yet.`
            : `Proposal ${adopting} was written from version ${rebased.from}, and the rubric has moved on to version ${rebased.to} since: what the proposal changes was moved onto it. It is not saved yet.`
          : `Your edits were moved from version ${rebased.from} onto version ${rebased.to}, which someone else saved meanwhile. They are not saved yet.`}
        {rebased.conflicts.length === 0
          ? " Nothing you changed was changed there too."
          : open > 0
            ? ` Both sides changed ${open === 1 ? "one thing" : `${open} things`}; choose which to keep.`
            : " Every conflict has a side; save when ready."}
      </p>
      {rebased.conflicts.map((c) => {
        const cid = rubricConflictId(c);
        const [mine, theirs] =
          c.kind === "type"
            ? [showType(c.mine), showType(c.theirs)]
            : c.kind === "category"
              ? [showCategory(c.mine), showCategory(c.theirs)]
              : c.kind === "order"
                ? [c.mineNames.join(", "), c.theirsNames.join(", ")]
                : [showValue(c.mine), showValue(c.theirs)];
        return (
          <fieldset key={cid} className="conflict">
            <legend>{conflictLabel(c)}</legend>
            <label className="side">
              <input
                type="radio"
                name={cid}
                checked={rebased.picks[cid] === "mine"}
                onChange={() => onPick(c, "mine")}
              />
              <span>
                {fromProposal ? "Keep the proposal's" : "Keep mine"}
                <span className="value">{mine}</span>
              </span>
            </label>
            <label className="side">
              <input
                type="radio"
                name={cid}
                checked={rebased.picks[cid] === "theirs"}
                onChange={() => onPick(c, "theirs")}
              />
              <span>
                {fromProposal ? "Keep the rubric's" : "Keep theirs"} (version {rebased.to})
                <span className="value">{theirs}</span>
              </span>
            </label>
          </fieldset>
        );
      })}
    </section>
  );
}

/**
 * Every version of the document, newest first and paged as the server pages it, with any one of
 * them shown as it was. `?version=N` opens version N: a job links to the rubric it was written to.
 */
function RubricHistory({
  owner,
  name,
  current,
  nonce,
  canRestore,
  onRestore,
  onUnauthorized,
}: {
  owner: string;
  name: string;
  current: RubricDocument;
  /** Changed after a save: the history is loaded again. */
  nonce: number;
  canRestore: boolean;
  onRestore: (v: RubricDocument) => void;
  onUnauthorized: () => void;
}) {
  const [params, setParams] = useSearchParams();
  const asked = params.get("version");
  const wanted = asked !== null && /^[0-9]+$/.test(asked) ? Number(asked) : null;
  const [items, setItems] = useState<RubricDocument[] | null>(null);
  const [next, setNext] = useState<number | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [viewed, setViewed] = useState<RubricDocument | null>(null);

  const fail = useCallback(
    (err: unknown) => {
      if (err instanceof UnauthorizedError) onUnauthorized();
      else setError(err instanceof Error ? err.message : String(err));
    },
    [onUnauthorized],
  );

  useEffect(() => {
    let live = true;
    api
      .rubricHistory(owner, name, 20, 0)
      .then((p) => {
        if (!live) return;
        setItems(p.items);
        setNext(p.nextOffset);
      })
      .catch((err: unknown) => live && fail(err));
    return () => {
      live = false;
    };
  }, [owner, name, nonce, fail]);

  // The version the address names, found wherever in the history it is.
  useEffect(() => {
    if (wanted === null) {
      setViewed(null);
      return;
    }
    let live = true;
    api
      .rubricAt(owner, name, wanted)
      .then((v) => {
        if (!live) return;
        setViewed(v);
        requestAnimationFrame(() => document.getElementById("viewed-h")?.focus());
      })
      .catch((err: unknown) => live && fail(err));
    return () => {
      live = false;
    };
  }, [owner, name, wanted, fail]);

  const more = () => {
    if (next === null) return;
    setBusy(true);
    api
      .rubricHistory(owner, name, 20, next)
      .then((p) => {
        setItems((xs) => [...(xs ?? []), ...p.items]);
        setNext(p.nextOffset);
      })
      .catch(fail)
      .finally(() => setBusy(false));
  };

  const view = (v: number | null) =>
    setParams(
      (ps) => {
        const out = new URLSearchParams(ps);
        if (v === null) out.delete("version");
        else out.set("version", String(v));
        return out;
      },
      { replace: false },
    );

  return (
    <section aria-labelledby="rubric-history-h">
      <h2 id="rubric-history-h">Versions</h2>
      {error !== null && (
        <p className="error" role="alert">
          {error}
        </p>
      )}
      {viewed !== null && (
        <section className="notice viewed" aria-labelledby="viewed-h">
          <h3 id="viewed-h" tabIndex={-1}>
            Version {viewed.version}
            {viewed.version === current.version && " (the current one)"}
          </h3>
          <p className="mute small-text data">{viewed.createdAt ?? ""}</p>
          <ShownRubric v={viewed} />
          <Provenance owner={owner} name={name} v={viewed} />
          <div className="actions">
            {canRestore && viewed.version !== current.version && documentOf(viewed) !== null && (
              <button type="button" onClick={() => onRestore(viewed)}>
                Restore as a new version…
              </button>
            )}
            <button type="button" className="ghost" onClick={() => view(null)}>
              Close
            </button>
          </div>
          {canRestore && viewed.version !== current.version && (
            <p className="mute small-text">
              Restoring puts this version into the editor above as unsaved edits; saving makes it
              version {current.version + 1}. Nothing is overwritten.
            </p>
          )}
        </section>
      )}
      {items === null ? (
        error === null && <p className="mute">Loading the versions…</p>
      ) : items.length === 0 ? (
        <p className="mute">No versions yet: the first save makes version 1.</p>
      ) : (
        <div className="table-scroll">
          <table>
            <thead>
              <tr>
                <th>Version</th>
                <th>Written</th>
                <th>Types</th>
                <th>Derived from</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {items.map((v) => (
                <tr key={v.version} className={viewed?.version === v.version ? "picked" : ""}>
                  <td className="data">
                    {v.version}
                    {v.version === current.version && <span className="tag">current</span>}
                  </td>
                  <td className="data mute">{v.createdAt ?? "—"}</td>
                  <td>
                    {v.prTypes === null ? (
                      <span className="tag warn">unreadable</span>
                    ) : v.prTypes.length === 0 ? (
                      <span className="mute">none</span>
                    ) : (
                      v.prTypes.map((t) => t.name).join(", ")
                    )}
                  </td>
                  <td className="small-text">{derivedSummary(v)}</td>
                  <td className="right">
                    <button
                      type="button"
                      className="ghost small"
                      aria-label={`View version ${v.version}`}
                      onClick={() => view(v.version)}
                    >
                      View
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {next !== null && (
        <div className="actions">
          <button type="button" className="ghost" onClick={more} disabled={busy}>
            Load older versions
          </button>
        </div>
      )}
    </section>
  );
}

/** A version as it was, all of it as text. */
function ShownRubric({ v }: { v: RubricDocument }) {
  const d = documentOf(v);
  if (d === null)
    return (
      <p className="error">
        This version cannot be read by this version of the platform:{" "}
        <span className="body">{v.documentError}</span>
      </p>
    );
  return (
    <>
      <h4>Default rubric</h4>
      <div className="preview body">
        {d.defaultRubric === "" ? <span className="mute">(empty)</span> : d.defaultRubric}
      </div>
      <h4>Pull request types</h4>
      {d.prTypes.length === 0 ? (
        <p className="mute">None.</p>
      ) : (
        d.prTypes.map((t, i) => (
          <div key={i} className="shown-type">
            <h5 className="data">{t.name}</h5>
            {t.description !== "" && <p className="body">{t.description}</p>}
            <div className="preview body">
              {t.rubric === "" ? <span className="mute">(no rubric of its own)</span> : t.rubric}
            </div>
            {t.categories.length === 0 ? (
              <p className="mute small-text">No categories: free text.</p>
            ) : (
              <dl className="cats-shown">
                {t.categories.map((c, j) => (
                  <div key={j}>
                    <dt className="data">{c.name}</dt>
                    <dd className="body">{c.description}</dd>
                  </div>
                ))}
              </dl>
            )}
          </div>
        ))
      )}
    </>
  );
}

/** What a version was derived from, counted: its samples and pull requests, or nothing. */
function derivedSummary(v: Pick<RubricDocument, "derivedFrom" | "derivedFromPulls">) {
  const samples = v.derivedFrom ?? [];
  const pulls = v.derivedFromPulls ?? [];
  if (v.derivedFrom === undefined && v.derivedFromPulls === undefined)
    return <span className="mute">not recorded</span>;
  if (samples.length === 0 && pulls.length === 0) return <span className="mute">nothing</span>;
  const n = (k: number, one: string, many: string) => `${k} ${k === 1 ? one : many}`;
  return `${n(samples.length, "sample", "samples")}, ${n(pulls.length, "pull request", "pull requests")}`;
}

/**
 * A pull request as the server names it, `owner/name#n`, split; null for anything else, a segment
 * that starts with a dot among them (`..`, which would leave the repository in a link).
 */
function pullOf(key: string): { slug: string; pr: number } | null {
  const m = /^([A-Za-z0-9_-][A-Za-z0-9._-]*\/[A-Za-z0-9_-][A-Za-z0-9._-]*)#([0-9]+)$/.exec(key);
  return m === null ? null : { slug: m[1] as string, pr: Number(m[2]) };
}

/**
 * The provenance of a version: the calibration samples and pull requests the proposal it came
 * from drew on, and every earlier version's. A score of any of them, made under this version, is
 * derived: left out of calibration's aggregates unless asked.
 */
function Provenance({ owner, name, v }: { owner: string; name: string; v: RubricDocument }) {
  const samples = v.derivedFrom ?? [];
  const pulls = v.derivedFromPulls ?? [];
  if (v.derivedFrom === undefined && v.derivedFromPulls === undefined) return null;
  const base = `/repos/${encodeURIComponent(owner)}/${encodeURIComponent(name)}/calibration`;
  return (
    <section className="provenance" aria-labelledby="provenance-h">
      <h4 id="provenance-h">Derived from</h4>
      {samples.length === 0 && pulls.length === 0 ? (
        <p className="mute small-text">
          Nothing: no rubric proposal reached this version or an earlier one.
        </p>
      ) : (
        <>
          <p className="mute small-text">
            What the rubric proposals that reached this version, or an earlier one, drew on.
            Calibration scores of these pull requests made under this version are derived: left out
            of the aggregates unless asked.
          </p>
          <h5>Pull requests ({pulls.length})</h5>
          {pulls.length === 0 ? (
            <p className="mute small-text">None.</p>
          ) : (
            <ul className="chips">
              {pulls.map((k) => {
                const p = pullOf(k);
                return (
                  <li key={k} className="data">
                    {p === null ? (
                      k
                    ) : (
                      <a
                        href={`https://github.com/${p.slug}/pull/${p.pr}`}
                        rel="noreferrer noopener"
                        target="_blank"
                      >
                        {k}
                      </a>
                    )}
                  </li>
                );
              })}
            </ul>
          )}
          <h5>Calibration samples ({samples.length})</h5>
          {samples.length === 0 ? (
            <p className="mute small-text">None.</p>
          ) : (
            <ul className="chips">
              {samples.map((id) => (
                <li key={id} className="data">
                  <Link to={`${base}/samples/${encodeURIComponent(id)}`}>{id}</Link>
                </li>
              ))}
            </ul>
          )}
        </>
      )}
    </section>
  );
}