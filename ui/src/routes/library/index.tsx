import { useEffect, useState } from "react";
import { allowVideoPaths, getLibrary } from "../../ipc/sidecar";
import type { LibraryDetail } from "./types";
import "./library.css";

type LoadState =
  | { kind: "loading" }
  | { kind: "ready"; library: LibraryDetail; selected: string }
  | { kind: "error"; message: string };

export default function Library({ name }: { name: string }) {
  const [state, setState] = useState<LoadState>({ kind: "loading" });

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const library = await getLibrary(name);
        if (library.video_paths_root) {
          await allowVideoPaths(library.video_paths_root);
        }
        if (cancelled) return;
        const selected = library.videos[0]?.filename ?? "";
        setState({ kind: "ready", library, selected });
      } catch (err) {
        if (!cancelled) setState({ kind: "error", message: String(err) });
      }
    })();
    return () => { cancelled = true; };
  }, [name]);

  if (state.kind === "loading") {
    return <main className="library"><p className="library__loading">Loading {name}…</p></main>;
  }
  if (state.kind === "error") {
    return (
      <main className="library">
        <div className="library__error">
          <p>Couldn't load library "{name}".</p>
          <pre>{state.message}</pre>
        </div>
      </main>
    );
  }

  return (
    <main className="library">
      <p className="library__loading">Loaded {state.library.videos.length} clips. Selected: {state.selected || "(none)"}.</p>
    </main>
  );
}
