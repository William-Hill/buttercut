import type { MutableRefObject } from "react";
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
import {
  listenRoughcutJobEvents,
  type RoughcutArtifactPaths,
  type RoughcutClip,
  type RoughcutJobEvent,
} from "../../ipc/events";

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

const MIN_TARGET_DURATION = 5;
const MAX_TARGET_DURATION = 86_400;

function clampTargetSeconds(raw: number): number {
  if (!Number.isFinite(raw)) return MIN_TARGET_DURATION;
  return Math.max(MIN_TARGET_DURATION, Math.min(MAX_TARGET_DURATION, Math.floor(raw)));
}

const ARTIFACT_PATH_KEYS: (keyof RoughcutArtifactPaths)[] = [
  "xml_path",
  "yaml_path",
  "recipe_path",
  "apply_path",
];

function disposeRoughcutListener(
  unlisten: () => void,
  ref: MutableRefObject<(() => void) | null>,
): void {
  unlisten();
  if (ref.current === unlisten) ref.current = null;
}

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
  const [donePaths, setDonePaths] = useState<RoughcutArtifactPaths | null>(null);
  const [clips, setClips] = useState<RoughcutClip[]>([]);
  const activeJobIdRef = useRef<string | null>(null);
  const unlistenRef = useRef<(() => void) | null>(null);

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
    try {
      const { id } = await upsertBrief({
        library,
        prompt,
        targetDurationSeconds: clampTargetSeconds(targetSeconds),
        id: currentBriefId ?? undefined,
      });
      setCurrentBriefId(id);
      await refreshBriefs();
    } catch (e) {
      setError(String(e));
    }
  }

  async function handleFork(parentId: string) {
    setError(null);
    try {
      const { id } = await forkBrief(library, parentId);
      const row = briefs.find((b) => b.id === parentId);
      setCurrentBriefId(id);
      if (row) {
        setPrompt(row.prompt);
        setTargetSeconds(clampTargetSeconds(row.target_duration_seconds));
      }
      await refreshBriefs();
    } catch (e) {
      setError(String(e));
    }
  }

  async function handleGenerate() {
    setError(null);
    setDonePaths(null);
    setClips([]);
    setPhaseMessage(null);
    unlistenRef.current?.();
    unlistenRef.current = null;

    try {
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

      const duration = clampTargetSeconds(targetSeconds);
      setTargetSeconds(duration);

      const { id: briefId } = await upsertBrief({
        library,
        prompt,
        targetDurationSeconds: duration,
        id: currentBriefId ?? undefined,
      });
      setCurrentBriefId(briefId);

      const started = await startRoughcut(library, briefId);
      const jobId = started.job_id;

      activeJobIdRef.current = jobId;
      setJobRunning(true);

      const unlisten = await listenRoughcutJobEvents(jobId, (ev: RoughcutJobEvent) => {
        switch (ev.method) {
          case "roughcut_phase":
            setPhaseMessage(ev.params.message ?? ev.params.phase);
            break;
          case "roughcut_job_done":
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
            disposeRoughcutListener(unlisten, unlistenRef);
            break;
          case "roughcut_job_failed":
            setError(ev.params.message);
            setJobRunning(false);
            setPhaseMessage(null);
            activeJobIdRef.current = null;
            disposeRoughcutListener(unlisten, unlistenRef);
            break;
          default:
            break;
        }
      });
      unlistenRef.current = unlisten;
    } catch (e) {
      setError(String(e));
      setJobRunning(false);
      setPhaseMessage(null);
      activeJobIdRef.current = null;
      unlistenRef.current?.();
      unlistenRef.current = null;
    }
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
            onChange={(e) => {
              const raw = Number(e.target.value);
              if (!Number.isFinite(raw)) return;
              setTargetSeconds(clampTargetSeconds(raw));
            }}
          />

          <div className="brief-composer__actions">
            <button type="button" className="brief-composer__btn" onClick={() => void handleSaveBrief()}>
              Save brief
            </button>
            <button
              type="button"
              className="brief-composer__btn brief-composer__btn--primary"
              disabled={jobRunning || !prompt.trim() || targetSeconds < MIN_TARGET_DURATION}
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
                    setTargetSeconds(clampTargetSeconds(b.target_duration_seconds));
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
                {ARTIFACT_PATH_KEYS.map((key) => (
                  <li key={key}>
                    <button
                      type="button"
                      className="brief-composer__linkish"
                      onClick={() => void revealItemInDir(donePaths[key])}
                    >
                      {donePaths[key]}
                    </button>
                  </li>
                ))}
              </ul>
            </div>
          )}
        </div>
      )}
    </section>
  );
}
