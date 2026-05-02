import { useEffect, useState } from "react";
import { listLibraries, openLibraryWindow, LibrarySummary } from "../ipc/sidecar";
import "./projects.css";

type LoadState =
  | { kind: "loading" }
  | { kind: "ready"; libraries: LibrarySummary[] }
  | { kind: "error"; message: string };

export default function Projects() {
  const [state, setState] = useState<LoadState>({ kind: "loading" });

  useEffect(() => {
    listLibraries()
      .then((libraries) => setState({ kind: "ready", libraries }))
      .catch((err) => setState({ kind: "error", message: String(err) }));
  }, []);

  return (
    <main className="projects">
      <header className="projects__header">
        <h1 className="projects__title">ButterCut</h1>
        <p className="projects__subtitle">Your libraries</p>
      </header>

      {state.kind === "loading" && <p className="projects__status">Reading libraries…</p>}

      {state.kind === "error" && (
        <div className="projects__status projects__status--error">
          <p>Couldn't reach the sidecar.</p>
          <pre>{state.message}</pre>
        </div>
      )}

      {state.kind === "ready" && state.libraries.length === 0 && (
        <p className="projects__status">No libraries yet. Create one with the CLI for now.</p>
      )}

      {state.kind === "ready" && state.libraries.length > 0 && (
        <ul className="projects__grid">
          {state.libraries.map((lib) => (
            <li key={lib.name}>
              <button
                className="card"
                onClick={() => openLibraryWindow(lib.name).catch(console.error)}
              >
                <span className="card__name">{lib.name}</span>
                <span className="card__meta">
                  <span className="card__count">{lib.video_count}</span>
                  <span className="card__count-label">
                    {lib.video_count === 1 ? "clip" : "clips"}
                  </span>
                </span>
                <span className="card__touched">{formatTouched(lib.last_touched_at)}</span>
              </button>
            </li>
          ))}
        </ul>
      )}
    </main>
  );
}

function formatTouched(iso: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return iso;
  const diffMs = Date.now() - date.getTime();
  const day = 24 * 60 * 60 * 1000;
  if (diffMs < day) return "today";
  if (diffMs < 2 * day) return "yesterday";
  if (diffMs < 30 * day) return `${Math.floor(diffMs / day)} days ago`;
  return date.toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
}
