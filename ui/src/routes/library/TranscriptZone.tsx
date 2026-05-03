import { useEffect, useState } from "react";
import { getClipTranscripts } from "../../ipc/sidecar";
import type { ClipTranscripts } from "./types";
import { formatTimestamp, interleave, InterleavedRow } from "./interleave";

interface Props {
  library: string;
  video: string | null;
  onSeek: (seconds: number) => void;
}

type LoadState =
  | { kind: "idle" }
  | { kind: "loading"; library: string; video: string }
  | { kind: "ready"; library: string; video: string; transcripts: ClipTranscripts }
  | { kind: "error"; library: string; video: string; message: string };

function matchesActive(state: LoadState, library: string, video: string | null): boolean {
  if (state.kind === "idle") return false;
  return state.library === library && state.video === video;
}

export default function TranscriptZone({ library, video, onSeek }: Props) {
  const [state, setState] = useState<LoadState>({ kind: "idle" });

  useEffect(() => {
    if (!video) {
      setState({ kind: "idle" });
      return;
    }
    let cancelled = false;
    setState({ kind: "loading", library, video });
    getClipTranscripts(library, video)
      .then((transcripts) => { if (!cancelled) setState({ kind: "ready", library, video, transcripts }); })
      .catch((err) => { if (!cancelled) setState({ kind: "error", library, video, message: String(err) }); });
    return () => { cancelled = true; };
  }, [library, video]);

  // Ignore results that don't belong to the currently selected clip.
  if (!matchesActive(state, library, video)) {
    return <div className="transcript-zone transcript-zone--empty">{video ? "Loading transcripts…" : "No clip selected."}</div>;
  }

  if (state.kind === "idle" || !video) {
    return <div className="transcript-zone transcript-zone--empty">No clip selected.</div>;
  }
  if (state.kind === "loading") {
    return <div className="transcript-zone transcript-zone--empty">Loading transcripts…</div>;
  }
  if (state.kind === "error") {
    return (
      <div className="transcript-zone transcript-zone--empty">
        <p>Couldn't load transcripts.</p>
        <pre>{state.message}</pre>
      </div>
    );
  }

  const visualSegments = state.transcripts.visual?.segments ?? [];
  const audioSegments = state.transcripts.audio?.segments ?? [];

  if (visualSegments.length === 0 && audioSegments.length === 0) {
    return <div className="transcript-zone transcript-zone--empty">This clip hasn't been analyzed yet.</div>;
  }

  // Visual transcript drives the screenplay layout; without it, render audio
  // segments standalone so audio-only clips don't render as a blank pane.
  if (visualSegments.length === 0) {
    return (
      <div className="transcript-zone">
        {audioSegments.map((seg, i) => (
          <AudioRow key={i} segment={seg} onSeek={onSeek} />
        ))}
      </div>
    );
  }

  const rows = interleave(visualSegments, audioSegments);

  return (
    <div className="transcript-zone">
      {rows.map((row, i) => (
        <Row key={i} row={row} onSeek={onSeek} />
      ))}
    </div>
  );
}

function Row({ row, onSeek }: { row: InterleavedRow; onSeek: (s: number) => void }) {
  return (
    <div className="row">
      <button className="row__visual" onClick={() => onSeek(row.visual.start)}>
        <span className="row__time">[{formatTimestamp(row.visual.start)}]</span>
        <span className="row__visual-text">{row.visual.visual}</span>
        {row.visual.b_roll && <span className="row__chip">b-roll</span>}
      </button>
      {row.audio.map((seg, j) => (
        <AudioRow key={j} segment={seg} onSeek={onSeek} />
      ))}
    </div>
  );
}

function AudioRow({ segment, onSeek }: { segment: import("./types").AudioSegment; onSeek: (s: number) => void }) {
  if (segment.words && segment.words.length > 0) {
    return (
      <p className="row__audio">
        <span className="row__time">[{formatTimestamp(segment.start)}]</span>
        {segment.words.map((w, i) => (
          <button key={i} className="row__word" onClick={() => onSeek(w.start)}>{w.word}</button>
        ))}
      </p>
    );
  }
  return (
    <p className="row__audio">
      <button className="row__audio-text" onClick={() => onSeek(segment.start)}>
        <span className="row__time">[{formatTimestamp(segment.start)}]</span>
        {segment.text}
      </button>
    </p>
  );
}
