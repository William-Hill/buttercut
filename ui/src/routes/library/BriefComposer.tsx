import type { MutableRefObject } from "react";
import { useCallback, useEffect, useRef, useState } from "react";
import { openPath, revealItemInDir } from "@tauri-apps/plugin-opener";
import {
  cancelJob,
  exportRoughcutArtifacts,
  forkBrief,
  hasApiKey,
  listBriefs,
  readLibraryTextFile,
  roughcutPrerequisites,
  sendToResolve,
  startRoughcut,
  upsertBrief,
} from "../../ipc/sidecar";
import { parseRoughcutRecipeJson, type RecipeJson } from "../../lib/recipeTypes";
import type { VideoEntry } from "./types";
import RoughcutStagePreview from "./RoughcutStagePreview";
import RoughcutTimeline from "./RoughcutTimeline";
import { AddBrollButton } from "./AddBrollButton";
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
type ExportFormat = "resolve" | "premiere" | "fcpx";

function normalizeSlashes(p: string): string {
  return p.replace(/\\/g, "/");
}

function dirname(path: string): string {
  const n = normalizeSlashes(path).replace(/\/+$/, "");
  if (!n) return ".";
  const i = n.lastIndexOf("/");
  if (i < 0) return ".";
  if (i === 0) return "/";
  return n.slice(0, i) || ".";
}

function basenameNoExt(path: string): string {
  const n = normalizeSlashes(path);
  const leaf = n.split("/").pop() ?? path;
  const lastDot = leaf.lastIndexOf(".");
  if (lastDot <= 0) return leaf;
  return leaf.slice(0, lastDot);
}

function normalizeSidecarError(error: unknown): string {
  if (error instanceof Error) return error.message;
  if (error && typeof error === "object" && "message" in error) {
    const msg = (error as { message?: unknown }).message;
    if (typeof msg === "string" && msg.trim()) return msg.trim();
  }
  const text = String(error);
  try {
    const parsed = JSON.parse(text) as { message?: string };
    if (parsed.message && parsed.message.trim()) return parsed.message;
    return text;
  } catch {
    return text;
  }
}

function disposeRoughcutListener(
  unlisten: () => void,
  ref: MutableRefObject<(() => void) | null>,
): void {
  unlisten();
  if (ref.current === unlisten) ref.current = null;
}

export default function BriefComposer({ library, videos }: { library: string; videos: VideoEntry[] }) {
  const [prereqOk, setPrereqOk] = useState<boolean | null>(null);
  const [prereqMissing, setPrereqMissing] = useState<PrereqRow[]>([]);
  const [briefs, setBriefs] = useState<BriefRow[]>([]);
  const [prompt, setPrompt] = useState("");
  const [targetSeconds, setTargetSeconds] = useState(120);
  const [currentBriefId, setCurrentBriefId] = useState<string | null>(null);
  const [phaseMessage, setPhaseMessage] = useState<string | null>(null);
  const [phaseStartedAt, setPhaseStartedAt] = useState<number | null>(null);
  const [phaseElapsedSec, setPhaseElapsedSec] = useState(0);
  const [jobRunning, setJobRunning] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [donePaths, setDonePaths] = useState<RoughcutArtifactPaths | null>(null);
  const [clips, setClips] = useState<RoughcutClip[]>([]);
  const [recipe, setRecipe] = useState<RecipeJson | null>(null);
  const [playheadSec, setPlayheadSec] = useState(0);
  const [playing, setPlaying] = useState(false);
  const [exportFormat, setExportFormat] = useState<ExportFormat>("resolve");
  const [exportFilename, setExportFilename] = useState("");
  const [exportBusy, setExportBusy] = useState(false);
  const [exportStatus, setExportStatus] = useState<string | null>(null);
  const [exportError, setExportError] = useState<string | null>(null);
  const activeJobIdRef = useRef<string | null>(null);
  const unlistenRef = useRef<(() => void) | null>(null);
  const recipeReadTokenRef = useRef(0);

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

  // Tick once per second so the phase message can show elapsed time.
  useEffect(() => {
    if (phaseStartedAt === null) {
      setPhaseElapsedSec(0);
      return;
    }
    setPhaseElapsedSec(Math.floor((Date.now() - phaseStartedAt) / 1000));
    const id = window.setInterval(() => {
      setPhaseElapsedSec(Math.floor((Date.now() - phaseStartedAt) / 1000));
    }, 1000);
    return () => window.clearInterval(id);
  }, [phaseStartedAt]);

  useEffect(() => {
    setPlayheadSec(0);
    setPlaying(false);
    if (donePaths?.yaml_path) {
      setExportFilename(basenameNoExt(donePaths.yaml_path));
      setExportStatus(null);
      setExportError(null);
    }
  }, [donePaths?.yaml_path]);

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
    setRecipe(null);
    setPlayheadSec(0);
    setPlaying(false);
    setPhaseMessage(null);
    unlistenRef.current?.();
    unlistenRef.current = null;

    const runToken = ++recipeReadTokenRef.current;

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
      setPhaseStartedAt(Date.now());

      const unlisten = await listenRoughcutJobEvents(jobId, (ev: RoughcutJobEvent) => {
        switch (ev.method) {
          case "roughcut_phase":
            setPhaseMessage(ev.params.message ?? ev.params.phase);
            setPhaseStartedAt(Date.now());
            break;
          case "roughcut_job_done":
            setDonePaths({
              yaml_path: ev.params.yaml_path,
              xml_path: ev.params.xml_path,
              recipe_path: ev.params.recipe_path,
              apply_path: ev.params.apply_path,
            });
            setClips(ev.params.clips);
            void readLibraryTextFile(ev.params.recipe_path)
              .then((raw) => {
                if (recipeReadTokenRef.current !== runToken) return;
                setRecipe(parseRoughcutRecipeJson(raw));
              })
              .catch(() => {
                if (recipeReadTokenRef.current !== runToken) return;
                setRecipe(null);
              });
            setJobRunning(false);
            setPhaseMessage(null);
            setPhaseStartedAt(null);
            setExportFormat("resolve");
            activeJobIdRef.current = null;
            disposeRoughcutListener(unlisten, unlistenRef);
            break;
          case "roughcut_job_failed":
            setError(ev.params.message);
            setJobRunning(false);
            setPhaseMessage(null);
            setPhaseStartedAt(null);
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
      setPhaseStartedAt(null);
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
    setPhaseStartedAt(null);
  }

  async function handleExportArtifacts(format: ExportFormat): Promise<RoughcutArtifactPaths | null> {
    if (!donePaths) return null;
    setExportBusy(true);
    setExportError(null);
    setExportStatus(format === "resolve" ? "Preparing Resolve export…" : "Exporting artifacts…");
    try {
      const next = await exportRoughcutArtifacts(library, donePaths.yaml_path, format, exportFilename.trim());
      setDonePaths(next);
      setExportFormat(format);
      setExportStatus(`Export complete (${format.toUpperCase()}).`);
      try {
        const raw = await readLibraryTextFile(next.recipe_path);
        setRecipe(parseRoughcutRecipeJson(raw));
      } catch {
        setRecipe(null);
      }
      return next;
    } catch (e) {
      setExportStatus(null);
      setExportError(normalizeSidecarError(e));
      return null;
    } finally {
      setExportBusy(false);
    }
  }

  async function handleSendToResolve() {
    if (!donePaths) return;
    setExportError(null);
    setExportStatus("Sending to Resolve…");
    let target = donePaths;
    if (exportFormat !== "resolve") {
      const exported = await handleExportArtifacts("resolve");
      if (!exported) return;
      target = exported;
    }

    setExportBusy(true);
    try {
      const result = await sendToResolve(library, target.apply_path, target.recipe_path);
      setExportStatus(`Applied in Resolve project "${result.project_name}" on timeline "${result.timeline_name}".`);
    } catch (e) {
      setExportStatus(null);
      setExportError(normalizeSidecarError(e));
    } finally {
      setExportBusy(false);
    }
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
          {phaseMessage && (
            <p className="brief-composer__phase">
              {phaseMessage}
              {phaseStartedAt !== null && <> · {phaseElapsedSec}s</>}
            </p>
          )}
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
          <h3 className="brief-composer__results-title">Timeline preview</h3>
          <p className="brief-composer__results-lead">
            Clips in story order with editorial recipe glyphs. Scrub the bar to seek the preview.
          </p>
          <div className="brief-composer__chips" role="toolbar" aria-label="Rough cut iterations">
            <button
              type="button"
              className="brief-composer__chip brief-composer__chip--active"
              disabled={jobRunning || !prompt.trim() || prereqOk === false}
              onClick={() => void handleGenerate()}
              title="Runs the same generate pipeline again (full rough cut). Trim-level diff UI is planned."
            >
              Regenerate
            </button>
            <button
              type="button"
              className="brief-composer__chip"
              disabled
              title="TODO M4b+: append a tight pacing directive to the brief, re-run model, then show clip-level diff (trim/add/remove)."
            >
              Make tighter
            </button>
            <button
              type="button"
              className="brief-composer__chip"
              disabled
              title="TODO M4b+: steer speed ramps / slow motion in YAML and surface which clips changed."
            >
              Lean harder into slow-mo
            </button>
          </div>
          <RoughcutTimeline
            clips={clips}
            recipe={recipe}
            playheadSec={playheadSec}
            onPlayheadSecChange={setPlayheadSec}
            onScrubStart={() => setPlaying(false)}
          />
          <RoughcutStagePreview
            clips={clips}
            videos={videos}
            playheadSec={playheadSec}
            onPlayheadSecChange={setPlayheadSec}
            playing={playing}
            onPlayingChange={setPlaying}
          />

          <h3 className="brief-composer__results-title brief-composer__results-title--sub">Selected clips</h3>
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
            <div className="brief-composer__export-sheet">
              <h3 className="brief-composer__results-title">Export</h3>
              <p className="brief-composer__results-lead">
                Export uses the generated rough cut YAML as source and writes XML, recipe, and apply artifacts to the roughcuts
                folder.
              </p>
              <div className="brief-composer__export-grid">
                <label className="brief-composer__label" htmlFor="export-format">
                  Format
                </label>
                <select
                  id="export-format"
                  className="brief-composer__input"
                  value={exportFormat}
                  disabled={exportBusy}
                  onChange={(e) => setExportFormat(e.target.value as ExportFormat)}
                >
                  <option value="resolve">DaVinci Resolve</option>
                  <option value="premiere">Adobe Premiere</option>
                  <option value="fcpx">Final Cut Pro</option>
                </select>
                <label className="brief-composer__label" htmlFor="export-filename">
                  Filename (no extension)
                </label>
                <input
                  id="export-filename"
                  className="brief-composer__input"
                  value={exportFilename}
                  disabled={exportBusy}
                  onChange={(e) => setExportFilename(e.target.value)}
                />
              </div>
              <p className="brief-composer__paths-label">Output folder: {dirname(donePaths.yaml_path)}</p>
              <div className="brief-composer__actions">
                <button
                  type="button"
                  className="brief-composer__btn"
                  disabled={exportBusy || !exportFilename.trim()}
                  onClick={() => void handleExportArtifacts(exportFormat)}
                >
                  {exportBusy ? "Working…" : `Export ${exportFormat.toUpperCase()}`}
                </button>
                <button
                  type="button"
                  className="brief-composer__btn brief-composer__btn--primary"
                  disabled={exportBusy || !exportFilename.trim()}
                  onClick={() => void handleSendToResolve()}
                >
                  Send to Resolve
                </button>
                <AddBrollButton
                  library={library}
                  roughcutStem={basenameNoExt(donePaths.yaml_path)}
                  hasManifest={false}
                />
              </div>
              {exportStatus && <p className="brief-composer__phase">{exportStatus}</p>}
              {exportError && <pre className="brief-composer__error">{exportError}</pre>}
            </div>
          )}

          {donePaths && (
            <div className="brief-composer__paths">
              <p className="brief-composer__paths-label">Artifacts</p>
              <ul>
                {ARTIFACT_PATH_KEYS.map((key) => (
                  <li key={key}>
                    <span className="brief-composer__path-text">{donePaths[key]}</span>
                    <span className="brief-composer__path-actions">
                      <button type="button" className="brief-composer__linkish" onClick={() => void openPath(donePaths[key])}>
                        Open
                      </button>
                      <button
                        type="button"
                        className="brief-composer__linkish"
                        onClick={() => void revealItemInDir(donePaths[key])}
                      >
                        Reveal
                      </button>
                    </span>
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
