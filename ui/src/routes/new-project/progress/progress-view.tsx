import { useEffect, useReducer, useMemo, useState } from "react";
import { jobReducer, initialJobState, type JobReducerAction } from "../jobReducer";
import { ClipRow } from "./clip-row";
import { listenJobEvents, type JobEvent, type StageName } from "../../../ipc/events";
import { cancelJob, openLibraryWindow, startAnalysis } from "../../../ipc/sidecar";

export function ProgressView({
  jobId,
  library,
  onComplete,
  onRestartJob,
}: {
  jobId: string;
  library: string;
  onComplete: () => void;
  onRestartJob: (newJobId: string) => void;
}) {
  const [state, dispatch] = useReducer(jobReducer, initialJobState);
  const [expanded, setExpanded] = useState<string | null>(null);

  useEffect(() => {
    let disposed = false;
    let unlisten: (() => void) | null = null;
    void listenJobEvents(jobId, (evt: JobEvent) => dispatch(evt as JobReducerAction)).then((fn) => {
      if (disposed) {
        fn();
        return;
      }
      unlisten = fn;
    });
    return () => {
      disposed = true;
      unlisten?.();
    };
  }, [jobId]);

  const clipList = useMemo(() => Object.values(state.videos).sort((a, b) => a.video.localeCompare(b.video)), [state.videos]);

  const totalForBar = state.totals.total > 0 ? state.totals.total : clipList.length;
  const readyCount = clipList.filter(
    (c) =>
      c.stages.transcribe === "done" &&
      c.stages.analyze === "done" &&
      c.stages.summarize === "done",
  ).length;

  const barPct = (readyCount / Math.max(1, totalForBar)) * 100;

  const allClipsDone = clipList.length > 0 && clipList.every(
    (c) =>
      c.stages.transcribe === "done" &&
      c.stages.analyze === "done" &&
      c.stages.summarize === "done",
  );

  function onCancel() {
    if (!confirm("Cancel analysis? Files already analyzed will be kept.")) return;
    dispatch({ method: "_internal_canceling" });
    void cancelJob(jobId);
  }

  async function onRetry(_stage: StageName) {
    try {
      const { job_id } = await startAnalysis(library);
      onRestartJob(job_id);
    } catch (e) {
      console.error(e);
    }
  }

  const showFooter =
    state.status === "complete" || state.status === "canceled" || allClipsDone;

  return (
    <section className="np-progress">
      <header className="np-progress__header">
        <h2>Analyzing {library}</h2>
        {state.status === "running" ? (
          <button type="button" onClick={onCancel}>
            Cancel
          </button>
        ) : null}
        {state.status === "canceling" ? <span>Canceling…</span> : null}
      </header>

      <div className="np-progress__bar">
        <div style={{ width: `${barPct}%` }} />
      </div>
      <p className="np-progress__count">
        {readyCount} of {Math.max(totalForBar, clipList.length) || "?"} clips ready
        {state.totals.failed > 0 ? (
          <span className="np-progress__failed"> · {state.totals.failed} failed</span>
        ) : null}
      </p>

      <ul className="np-progress__list">
        {clipList.map((c) => (
          <li key={c.video}>
            <ClipRow
              clip={c}
              library={library}
              expanded={expanded === c.video}
              onToggle={() => setExpanded(expanded === c.video ? null : c.video)}
              onRetry={onRetry}
            />
          </li>
        ))}
      </ul>

      {showFooter ? (
        <footer className="np-progress__footer">
          <button type="button" onClick={() => void openLibraryWindow(library).then(onComplete)}>
            Open Library
          </button>
          <button type="button" className="np-progress__close" onClick={onComplete}>
            Close window
          </button>
        </footer>
      ) : null}
    </section>
  );
}
