import { useEffect } from "react";
import { open } from "@tauri-apps/plugin-dialog";
import { getCurrentWebview } from "@tauri-apps/api/webview";
import { inspectVideoPaths } from "../../../ipc/sidecar";
import type { SetupState, SetupAction } from "../state";

export function PickFootage({
  state,
  dispatch,
  onNext,
}: {
  state: SetupState;
  dispatch: React.Dispatch<SetupAction>;
  onNext: () => void;
}) {
  useEffect(() => {
    const unlistenP = getCurrentWebview().onDragDropEvent(async (event) => {
      if (event.payload.type === "drop") {
        const result = await inspectVideoPaths(event.payload.paths);
        dispatch({ type: "add_files", accepted: result.accepted, rejected: result.rejected });
      }
    });
    return () => {
      void unlistenP.then((fn) => fn());
    };
  }, [dispatch]);

  async function chooseFolder() {
    const picked = await open({ directory: true });
    if (picked == null) return;
    const path = typeof picked === "string" ? picked : picked[0];
    const result = await inspectVideoPaths([path]);
    dispatch({ type: "add_files", accepted: result.accepted, rejected: result.rejected });
  }

  async function chooseFiles() {
    const picked = await open({ multiple: true, filters: [{ name: "Video", extensions: ["mp4", "mov", "m4v", "mkv", "webm", "avi"] }] });
    if (picked == null) return;
    const paths = Array.isArray(picked) ? picked : [picked];
    const result = await inspectVideoPaths(paths);
    dispatch({ type: "add_files", accepted: result.accepted, rejected: result.rejected });
  }

  return (
    <section className="np-step">
      <h2>Pick footage</h2>
      <div className="np-dropzone">
        <p>Drop video files or a folder onto this window.</p>
        <p className="np-dropzone__hint">
          Folder button only adds files if the sidecar recognizes the path as a video; for full folders, use drag-and-drop (or choose files).
        </p>
        <div className="np-dropzone__buttons">
          <button type="button" onClick={() => void chooseFolder()}>
            Choose folder…
          </button>
          <button type="button" onClick={() => void chooseFiles()}>
            Choose files…
          </button>
        </div>
      </div>

      {state.accepted.length > 0 && (
        <ul className="np-filelist">
          {state.accepted.map((v) => (
            <li key={v.path}>
              <span className="np-filelist__name">{v.path.split("/").pop()}</span>
              <span className="np-filelist__dur">{formatDuration(v.duration_seconds)}</span>
              <button
                type="button"
                className="np-filelist__remove"
                onClick={() => dispatch({ type: "remove_file", path: v.path })}
              >
                ×
              </button>
            </li>
          ))}
        </ul>
      )}

      {state.rejected.length > 0 && (
        <details className="np-rejected">
          <summary>{state.rejected.length} skipped</summary>
          <ul>
            {state.rejected.map((r) => (
              <li key={r.path}>
                {r.path.split("/").pop()} — {r.reason}
              </li>
            ))}
          </ul>
        </details>
      )}

      <footer className="np-footer">
        <button type="button" disabled={state.accepted.length === 0} onClick={onNext}>
          Continue
        </button>
      </footer>
    </section>
  );
}

function formatDuration(s: number) {
  const m = Math.floor(s / 60);
  const r = Math.floor(s % 60);
  return `${m}:${String(r).padStart(2, "0")}`;
}
