import type { VideoEntry } from "./types";
import { useThumbnail } from "./useThumbnail";

interface Props {
  library: string;
  video: VideoEntry;
  selected: boolean;
  onSelect: () => void;
}

export default function ClipCard({ library, video, selected, onSelect }: Props) {
  const { ref, state } = useThumbnail(library, video.filename);
  const fullyAnalyzed = video.has_audio_transcript && video.has_visual_transcript && video.has_summary;
  const partiallyAnalyzed = video.has_audio_transcript || video.has_visual_transcript || video.has_summary;
  const dotClass = fullyAnalyzed ? "clip-card__dot--full" : partiallyAnalyzed ? "clip-card__dot--partial" : "clip-card__dot--none";

  return (
    <button
      ref={ref as unknown as React.RefObject<HTMLButtonElement>}
      className={`clip-card ${selected ? "clip-card--selected" : ""}`}
      onClick={onSelect}
      aria-pressed={selected}
    >
      <div className="clip-card__thumb" data-state={state.kind}>
        {state.kind === "ready" && <img src={state.src} alt="" />}
      </div>
      <div className="clip-card__meta">
        <span className="clip-card__name">{video.filename}</span>
        <span className="clip-card__row">
          <span className="clip-card__duration">{formatDuration(video.duration_seconds)}</span>
          <span className={`clip-card__dot ${dotClass}`} aria-label={analysisLabel(video)} />
        </span>
      </div>
    </button>
  );
}

function formatDuration(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds <= 0) return "—";
  const m = Math.floor(seconds / 60);
  const s = Math.floor(seconds % 60).toString().padStart(2, "0");
  return `${m}:${s}`;
}

function analysisLabel(v: VideoEntry): string {
  const parts: string[] = [];
  if (v.has_audio_transcript) parts.push("audio");
  if (v.has_visual_transcript) parts.push("visual");
  if (v.has_summary) parts.push("summary");
  return parts.length === 0 ? "not analyzed" : `analyzed: ${parts.join(", ")}`;
}
