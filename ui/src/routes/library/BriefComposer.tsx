import { useCallback, useEffect, useRef, useState } from "react";
import { revealItemInDir } from "@tauri-apps/plugin-opener";
import {
  cancelJob,
  forkBrief,
  hasApiKey,
  listBriefs,
  roughcutPrerequisites,
  startRoughcut,
  upsertBrief,
} from "../../ipc/sidecar";
import { listenRoughcutJobEvents, type RoughcutJobEvent } from "../../ipc/events";

export interface BriefRow {
  id: string;
  parent_id: string | null;
  prompt: string;
  target_duration_seconds: number;
  title: string;
  created_at: string;
  updated_at: string;
}

type PrereqRow = { video: string; missing: string[] };

export default function BriefComposer({ library }: { library: string }) {
  const [prereqOk, setPrereqOk] = useState<boolean | null>(null);
  const [prereqMissing, setPrereqMissing] = useState<PrereqRow[]>([]);
  const [briefs, setBriefs] = useState<BriefRow[]>([]);
  const [prompt, setPrompt] = useState("");
  const [targetSeconds, setTargetSeconds] = useState(120);
  const [currentBriefId, setCurrentBriefId] = useState<string | null>(null);
  const [phaseMessage, setPhaseMessage] = useState<string | null>(null);
  const [jobRunning, setJobRunning] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [donePaths, setDonePaths] = useState<{
    yaml_path: string;
    xml_path: string;
    recipe_path: string;
    apply_path: string;
  } | null>(null);
  const [clips, setClips] = useState<{ source_file: string; in_point: string; out_point: string }[]>([]);
  const activeJobIdRef = useRef<string | null>(null);
  const unlistenRef = useRef<null | (() => void)>(null);

  const refreshBriefs = useCallback(async () => {
    const r = await listBriefs(library);
    setBriefs((r.briefs as unknown as BriefRow[]) ?? []);
  }, [library]);

  const refreshPrereq = useCallback(async () => {
    const r = await roughcutPrerequisites(library);
    setPrereqOk(!!r.ok);
    setPrereqMissing(r.missing ?? []);
  }, [library]);

  useEffect(() => {
    void refreshPrereq();
    void refreshBriefs();
  }, [refreshBriefs, refreshPrereq]);

  useEffect(
    () => () => {
      unlistenRef.current?.();
      unlistenRef.current = null;
    },
    [],
  );

  async function handleSaveBrief() {
    setError(null);
    const { id } = await upsertBrief({
      library,
      prompt,
      targetDurationSeconds: targetSeconds,
      id: currentBriefId ?? undefined,
    });
    setCurrentBriefId(id);
    await refreshBriefs();
  }

  async function handleFork(parentId: string) {
    setError(null);
    const { id } = await forkBrief(library, parentId);
    const row = briefs.find((b) => b.id === parentId);
    setCurrentBriefId(id);
    if (row) {
      setPrompt(row.prompt);
      setTargetSeconds(row.target_duration_seconds);
    }
    await refreshBriefs();
  }

  async function handleGenerate() {
    setError(null);
    setDonePaths(null);
    setClips([]);
    setPhaseMessage(null);
    unlistenRef.current?.();
    unlistenRef.current = null;

    const key = await hasApiKey();
    if (!key.configured) {
      setError("Add your Anthropic API key in New Project before generating a rough cut.");
      return;
    }

    if (!prereqOk) {
      setError(
        "Footage analysis is incomplete for one or more clips. Finish transcripts, visuals, and summaries first.",
      );
      return;
    }

    const { id: briefId } = await upsertBrief({
      library,
      prompt,
      targetDurationSeconds: targetSeconds,
      id: currentBriefId ?? undefined,
    });
    setCurrentBriefId(briefId);

    let jobId: string;
    try {
      const started = await startRoughcut(library, briefId);
      jobId = started.job_id;
    } catch (e) {
      setError(String(e));
      return;
    }

    activeJobIdRef.current = jobId;
    setJobRunning(true);

    const unlisten = await listenRoughcutJobEvents(jobId, (ev: RoughcutJobEvent) => {
      if (ev.method === "roughcut_phase") {
        setPhaseMessage(ev.params.message ?? ev.params.phase);
      }
      if (ev.method === "roughcut_job_done") {
        setDonePaths({
          yaml_path: ev.params.yaml_path,
          xml_path: ev.params.xml_path,
          recipe_path: ev.params.recipe_path,
          apply_path: ev.params.apply_path,
        });
        setClips(ev.params.clips);
        setJobRunning(false);
        setPhaseMessage(null);
        activeJobIdRef.current = null;
        unlisten();
        if (unlistenRef.current === unlisten) unlistenRef.current = null;
      }
      if (ev.method === "roughcut_job_failed") {
        setError(ev.params.message);
        setJobRunning(false);
        setPhaseMessage(null);
        activeJobIdRef.current = null;
        unlisten();
        if (unlistenRef.current === unlisten) unlistenRef.current = null;
      }
    });
    unlistenRef.current = unlisten;
  }

  function handleCancelJob() {
    const id = activeJobIdRef.current;
    if (id) void cancelJob(id);
    unlistenRef.current?.();
    unlistenRef.current = null;
    activeJobIdRef.current = null;
    setJobRunning(false);
    setPhaseMessage(null);
  }

  return (
    <section className="brief-composer">
      <header className="brief-composer__header">
        <h2 className="brief-composer__title">Rough cut</h2>
        {prereqOk === false && (
          <p className="brief-composer__warn">
            Analysis incomplete. Each clip needs audio transcript, visual transcript, and summary.
            {prereqMissing.length > 0 && (
              <span className="brief-composer__warn-detail">
                {" "}
                Missing:{" "}
                {prereqMissing.map((m) => `${m.video} (${m.missing.join(", ")})`).join("; ")}
              </span>
            )}
          </p>
        )}
        {prereqOk && <p className="brief-composer__ok">All clips ready for rough cut generation.</p>}
      </header>

      <div className="brief-composer__grid">
        <div className="brief-composer__editor">
          <label className="brief-composer__label" htmlFor="brief-prompt">
            Brief
          </label>
          <textarea
            id="brief-prompt"
            className="brief-composer__textarea"
            rows={8}
            value={prompt}
            onChange={(e) => setPrompt(e.target.value)}
            placeholder="Describe the story, pacing, and what to include or avoid…"
          />

          <label className="brief-composer__label" htmlFor="brief-duration">
            Target duration (seconds)
          </label>
          <input
            id="brief-duration"
            className="brief-composer__input"
            type="number"
            min={5}
            max={86_400}
            value={targetSeconds}
            onChange={(e) => setTargetSeconds(Number(e.target.value) || 0)}
          />

          <div className="brief-composer__actions">
            <button type="button" className="brief-composer__btn" onClick={() => void handleSaveBrief()}>
              Save brief
            </button>
            <button
              type="button"
              className="brief-composer__btn brief-composer__btn--primary"
              disabled={jobRunning || !prompt.trim()}
              onClick={() => void handleGenerate()}
            >
              {jobRunning ? "Generating…" : "Generate"}
            </button>
            {jobRunning && (
              <button type="button" className="brief-composer__btn" onClick={handleCancelJob}>
                Cancel
              </button>
            )}
          </div>
          {phaseMessage && <p className="brief-composer__phase">{phaseMessage}</p>}
          {error && <pre className="brief-composer__error">{error}</pre>}
        </div>

        <aside className="brief-composer__history">
          <h3 className="brief-composer__history-title">Brief history</h3>
          <ul className="brief-composer__list">
            {briefs.map((b) => (
              <li key={b.id} className="brief-composer__history-item">
                <button
                  type="button"
                  className="brief-composer__history-load"
                  onClick={() => {
                    setCurrentBriefId(b.id);
                    setPrompt(b.prompt);
                    setTargetSeconds(b.target_duration_seconds);
                  }}
                >
                  Load
                </button>
                <button type="button" className="brief-composer__history-fork" onClick={() => void handleFork(b.id)}>
                  Fork
                </button>
                <div className="brief-composer__history-meta">
                  <span className="brief-composer__history-id">{b.id}</span>
                  <span className="brief-composer__history-time">{b.updated_at}</span>
                </div>
                <p className="brief-composer__history-snippet">
                  {b.prompt.slice(0, 120)}
                  {b.prompt.length > 120 ? "…" : ""}
                </p>
              </li>
            ))}
          </ul>
        </aside>
      </div>

      {clips.length > 0 && (
        <div className="brief-composer__results">
          <h3 className="brief-composer__results-title">Selected clips</h3>
          <table className="brief-composer__table">
            <thead>
              <tr>
                <th>Source</th>
                <th>In</th>
                <th>Out</th>
              </tr>
            </thead>
            <tbody>
              {clips.map((c, i) => (
                <tr key={`${c.source_file}-${i}`}>
                  <td>{c.source_file}</td>
                  <td className="brief-composer__mono">{c.in_point}</td>
                  <td className="brief-composer__mono">{c.out_point}</td>
                </tr>
              ))}
            </tbody>
          </table>

          {donePaths && (
            <div className="brief-composer__paths">
              <p className="brief-composer__paths-label">Artifacts (reveal in Finder)</p>
              <ul>
                <li>
                  <button
                    type="button"
                    className="brief-composer__linkish"
                    onClick={() => void revealItemInDir(donePaths.xml_path)}
                  >
                    {donePaths.xml_path}
                  </button>
                </li>
                <li>
                  <button
                    type="button"
                    className="brief-composer__linkish"
                    onClick={() => void revealItemInDir(donePaths.yaml_path)}
                  >
                    {donePaths.yaml_path}
                  </button>
                </li>
                <li>
                  <button
                    type="button"
                    className="brief-composer__linkish"
                    onClick={() => void revealItemInDir(donePaths.recipe_path)}
                  >
                    {donePaths.recipe_path}
                  </button>
                </li>
                <li>
                  <button
                    type="button"
                    className="brief-composer__linkish"
                    onClick={() => void revealItemInDir(donePaths.apply_path)}
                  >
                    {donePaths.apply_path}
                  </button>
                </li>
              </ul>
            </div>
          )}
        </div>
      )}
    </section>
  );
}
