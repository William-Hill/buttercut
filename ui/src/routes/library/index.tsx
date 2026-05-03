import { useEffect, useRef, useState } from "react";
import { allowVideoPaths, getLibrary } from "../../ipc/sidecar";
import type { LibraryDetail } from "./types";
import ClipGrid from "./ClipGrid";
import StageZone from "./StageZone";
import TranscriptZone from "./TranscriptZone";
import "./library.css";

type LoadState =
  | { kind: "loading" }
  | { kind: "ready"; library: LibraryDetail; selected: string }
  | { kind: "error"; message: string };

export default function Library({ name }: { name: string }) {
  const [state, setState] = useState<LoadState>({ kind: "loading" });
  const videoRef = useRef<HTMLVideoElement | null>(null);

  useEffect(() => {
    let cancelled = false;
    setState({ kind: "loading" });
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

  const selectedVideo = state.library.videos.find((v) => v.filename === state.selected);

  return (
    <main className="library">
      <ClipGrid
        library={state.library.name}
        videos={state.library.videos}
        selected={state.selected}
        onSelect={(filename) => setState({ kind: "ready", library: state.library, selected: filename })}
      />
      <div className="library__detail">
        <StageZone ref={videoRef} video={selectedVideo} footageSummary={state.library.footage_summary} />
        <TranscriptZone
          library={state.library.name}
          video={state.selected || null}
          onSeek={(seconds) => {
            const v = videoRef.current;
            if (v) v.currentTime = seconds;
          }}
        />
      </div>
    </main>
  );
}
